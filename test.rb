# frozen_string_literal: true

require "dotenv/load"
require "rest-client"
require "json"
require_relative "tournament"
require_relative "scene"
require_relative "bracket"
require_relative "team"
require_relative "match"
require_relative "player"
require_relative "config"

USE_CACHE = true
UPDATE_CACHE = true
API_KEY = ENV["CHALLONGE_API_KEY"]
SLUG = ENV["CHALLONGE_SLUG"]

# Sends a GET request to `url`, treats the returned data as JSON, parses it
# into an object, and returns that object.
# If `cache_file` exists and `USE_CACHE` is true, then `cache_file` will be
# read instead.
def send_get_request(url, cache_file, params = {})
    cached_response_file = "cache_#{cache_file}"
    params[:api_key] = API_KEY

    if USE_CACHE && File.exist?(cached_response_file)
        puts "Using the cached response from #{cached_response_file}"
        JSON.parse(IO.read(cached_response_file), symbolize_names: true)
    else
        resp = RestClient.get(url, params: params)
        IO.write(cached_response_file, resp) if UPDATE_CACHE

        JSON.parse(resp, symbolize_names: true)
    end
end

# Reads all the info about the tournament, and returns a struct that
# contains the state of the tournament.
def read_tournament
    tournament = get_tournament
    teams = get_teams(tournament)
    matches = get_matches(tournament)
    players = get_players(teams, tournament)

    OpenStruct.new(tournament: tournament, teams: teams,
                   matches: matches, players: players)
end

# Reads the tournament, team, and match info for the tournament.  Returns all
# that info in a hash that is built from the JSON that Challonge returns.
# See https://api.challonge.com/v1/documents/tournaments/show
def get_tournament
    url = "https://api.challonge.com/v1/tournaments/#{SLUG}.json"
    params = { include_matches: 1, include_participants: 1 }

    response = send_get_request(url, "#{SLUG}_tournament.json", params)
    tournament = OpenStruct.new(response[:tournament])

    # Find the match that has the config file attached to it.  By convention,
    # the file is attached to the first match, although we don't enforce that.
    # We just look for a match with exactly 1 attachment.
    first_match = tournament.matches.select { |match| match.dig(:match, :attachment_count) == 1 }

    raise "No attachments were found in the tournament" if first_match.empty?
    raise "Multiple matches have an attachment" if first_match.size > 1

    # Read the options from the config file that's attached to that match.
    url = "https://api.challonge.com/v1/tournaments/#{SLUG}/matches/" \
            "#{first_match.dig(0, :match, :id)}/attachments.json"

    attachment_list = send_get_request(url, "#{SLUG}_attachments.json")
    attachment = OpenStruct.new(attachment_list.dig(0, :match_attachment))

    raise "Couldn't find the config file attachment" if attachment.asset_url.nil?

    uri = URI(attachment.asset_url)

    # Attachment URLs seem to not have a scheme, and instead start with "//".
    # Default to HTTPS.
    uri.scheme = "https" if uri.scheme.nil?

    puts "Reading the config file from #{uri}"

    tournament.config = send_get_request(uri.to_s, "#{SLUG}_config_file.json")

    %i(base_point_value final_bracket max_players_to_count match_values).each do |key|
        raise "The config file is missing \"#{key}\"" unless tournament.config.key?(key)
    end

    tournament.base_point_value = tournament.config[:base_point_value]
    tournament.final_bracket = tournament.config[:final_bracket]
    tournament.max_players_to_count = tournament.config[:max_players_to_count]

    tournament
end

# Returns a hash where each key is a team ID, and the corresponding value is
# a struct that contains that team's info.  The `final_rank` field is non-nil
# only if the bracket has been finalized.
def get_teams(tournament)
    teams = {}

    tournament.participants.each do |team|
        s = OpenStruct.new(team[:participant])

        teams[s.id] = OpenStruct.new(name: s.name, final_rank: s.final_rank,
                                     points: 0.0)
    end

    puts "These teams are in the tournament: " +
           teams.each_value.sort_by(&:name).map { |t| %("#{t.name}") }.join(", ")

    teams
end

# Returns an array of structs that contain info about the matches in the tournament.
def get_matches(tournament)
    # Check that `match_values` in the config file is the right size.
    # The size must normally equal the number of matches.  However, if the
    # bracket is complete and it is double-elimination, then the array size is
    # allowed to be one more than the number of matches, to account for a grand
    # final that was only one match long.
    #
    # If this is a two-stage tournament, the matches in the first stage have
    # `suggested_play_order` set to nil, so don't consider those matches.
    # If there is a match for 3rd place, its `suggested_play_order` is nil.
    # We also ignore that match, and instead, assign points to the 3rd-place
    # and 4th-place teams after the tournament has finished.
    matches = []
    elim_stage_matches =
        tournament.matches.select { |m| m[:match][:suggested_play_order] }
    num_matches = elim_stage_matches.size
    array_size = tournament.config[:match_values].size

    if num_matches != array_size
        if tournament.state != "complete" ||
           tournament.tournament_type != "double elimination" ||
           array_size != num_matches + 1
            raise "match_values in the config file is the wrong size." \
                    " The size is #{array_size}, expected #{num_matches}."
        end
    end

    elim_stage_matches.each do |match|
        s = OpenStruct.new(match[:match])
        points = tournament.config[:match_values][s.suggested_play_order - 1]

        matches << OpenStruct.new(state: s.state, play_order: s.suggested_play_order,
                                  attachment_count: s.attachment_count,
                                  team1: s.player1_id, team2: s.player2_id,
                                  winner_id: s.winner_id, loser_id: s.loser_id,
                                  points: points)
    end

    matches.sort_by!(&:suggested_play_order)
end

# Returns a hash where each key is a team ID, and the corresponding value is an
# array of structs that contain info about the players on that team.
def get_players(teams, tournament)
    players = {}

    # Parse the team list and create structs for each player on the teams.
    tournament.config[:teams].each do |team|
        # Look up the team in the `teams` hash.  This is how we associate a
        # team in the config file with its ID on Challonge.
        team_id, _ = teams.find { |_, t| t.name.casecmp?(team[:name]) }

        # If the `find` call failed, then there is a team in the team list that
        # isn't in the bracket.  We allow this so that multiple brackets can
        # use the same master team list during a tournament.
        if team_id.nil?
            puts "Skipping a team that isn't in the bracket: #{team[:name]}"
            next
        end

        players[team_id] = []

        team[:players].each do |player|
            s = OpenStruct.new(player)
            players[team_id] << OpenStruct.new(name: s.name, scene: s.scene, points: 0.0)
        end

        puts "#{team[:name]} (ID #{team_id}) has: " +
             players[team_id].map { |p| "#{p.name} (#{p.scene})" }.join(", ")
    end

    # Bail out if any team doesn't have exactly 5 players.
    invalid_teams = players.select { |_, team| team.size != 5 }

    if invalid_teams.any?
        team_names = invalid_teams.each_key.map { |id| teams[id].name }.join(", ")
        raise "These teams don't have 5 players: #{team_names}"
    end

    players
end

# Calculates how many points each team has earned in the tournament.  If the
# tournament is not yet complete, the values are the mininum number of points
# that the team can receive based on their current position in the bracket.
def calculate_team_points(tournament_info)
    # If the tournament is complete, we can calculate points based on the
    # teams' `final_rank`s.
    if tournament_info.tournament.state == "complete"
        calculate_team_points_by_final_rank(tournament_info)
        return
    end

    # For each team, look at the matches that it is in, look at the point
    # values of those matches, and take the maximum point value.  That's the
    # number of points that the team has earned so far in the bracket.
    base_point_value = tournament_info.tournament.base_point_value

    tournament_info.teams.each do |team_id, team|
        matches_with_team = tournament_info.matches.select do |match|
            team_id == match.team1 || team_id == match.team2
        end

        puts "Team #{team.name} was in #{matches_with_team.size} matches"

        highest_value_match = matches_with_team.max_by(&:points)
        points_earned = highest_value_match.points

        puts "The largest point value of those matches is #{points_earned}" \
               "#{" + #{base_point_value} base" if base_point_value > 0}"

        team.points = points_earned + base_point_value
    end
end

# Calculates how many points each team earned in the tournament.
def calculate_team_points_by_final_rank(tournament_info)
    # Calculate how many points to award to each rank.  When multiple teams
    # have the same rank (e.g., two teams tie for 5th place), those teams
    # get the average of the points available to those ranks.  For example,
    # in a 6-team tournament, the teams in 1st through 4th place get 6 through 3
    # points respectively.  The two teams in 5th get 1.5, the average of 2 and 1.
    sorted_teams = tournament_info.teams.each_value.sort_by(&:final_rank)
    num_teams = sorted_teams.size.to_f

    final_rank_points = sorted_teams.each_with_index.
                          each_with_object({}) do |(team, idx), rank_points|
        rank_points[team.final_rank] ||= []
        rank_points[team.final_rank] << num_teams - idx
    end

    # For debugging: Print the points to be awarded to each rank.  We can
    # check the output to ensure that ranks where teams are tied are correctly
    # assigned multiple point values.
    final_rank_points.sort.each do |rank, points|
        puts "Points for rank #{rank} = #{points.join(', ')}"
    end

    base_point_value = tournament_info.tournament.base_point_value

    sorted_teams.each do |team|
        points_earned = final_rank_points[team.final_rank].sum /
                          final_rank_points[team.final_rank].size

        puts "#{team.name} finished in position #{team.final_rank} and gets" \
               " #{points_earned} points" \
               "#{" + #{base_point_value} base" if base_point_value > 0}"

        team.points = points_earned + base_point_value
    end
end

# Calculates how many points each player has earned in the tournament.
def calculate_player_points(tournament_info)
    # Sort the teams by points in descending order.  This way, the output will
    # follow the teams' finishing order, which will be easier to read.
    tournament_info.teams.sort do |a, b|
        b[1].points <=> a[1].points
    end.each do |team_id, team|
        puts "Awarding #{team.points} points to #{team.name}: " +
             tournament_info.players[team_id].map { |p| "#{p.name} (#{p.scene})" }.
             join(", ")

        tournament_info.players[team_id].each do |player|
            player.points = team.points
        end
    end
end

# Calculates how many points each scene has earned in the tournament.
# Returns an array of structs whose members are the scene name, the points that
# the scene earned, and the number of players whose scores were counted in
# the point total.
def calculate_scene_points(tournament_info)
    # Collect the scores of all players from the same scene.
    scene_scores = tournament_info.players.each_value.each_with_object({}) do |players, scores|
        players.each do |player|
            scores[player.scene] ||= []
            scores[player.scene] << player.points
        end
    end

    scene_scores.map do |scene, scores|
        # If a scene has more players than the max number of players whose scores
        # can be counted, drop the extra players' scores.
        # Sort the scores for each scene in descending order, so we only keep the
        # highest-scoring players.
        scores.sort! { |a, b| b <=> a }

        if scores.size > tournament_info.tournament.max_players_to_count
            dropped = scores.slice!(tournament_info.tournament.max_players_to_count..-1)

            puts "Dropping the #{dropped.size} lowest scores from #{scene}:" \
                   " #{dropped.join(', ')}"
        end

        # Add up the scores for each scene.
        OpenStruct.new(scene: scene, points: scores.sum, num_players: scores.size)
    end
end

# Calculates how many points have been earned in the tournament.
# Returns a hash whose keys are scene names, and whose values are the points
# that the scene has earned.
def calculate_points(tournament_info)
    calculate_team_points(tournament_info)
    calculate_player_points(tournament_info)
    calculate_scene_points(tournament_info)
end

def main
    output = calculate_points(read_tournament).sort do |a, b|
        # Sort by points descending, then scene name ascending.
        a.points != b.points ? b.points <=> a.points : a.scene <=> b.scene
    end.map do |result|
        "#{result.scene} earned #{result.points} points from #{result.num_players} players"
    end

    puts output
end

if __FILE__ == $0
    tournament = Tournament.new
    tournament.load(SLUG)
    tournament.calculate_points

    puts tournament.scene_scores.sort
end

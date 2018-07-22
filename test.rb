# frozen_string_literal: true

require "dotenv/load"
require "rest-client"
require "json"

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

# Reads all the info about the tournament, and returns an `OpenStruct` that
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
# that info in a hash.
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

    puts "Reading config file from #{uri}"

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
# an `OpenStruct` that contains that team's info.  The `final_rank` field is
# non-nil only if the bracket has been finalized.
def get_teams(tournament)
    teams = {}

    tournament.participants.each do |team|
        s = OpenStruct.new(team[:participant])
        puts "Team \"#{s.name}\" has ID #{s.id}"

        teams[s.id] = OpenStruct.new(name: s.name, final_rank: s.final_rank,
                                     points: 0.0)
    end

    teams
end

# Returns a hash where each key is a match ID, and the corresponding value is
# an `OpenStruct` that contains that match's info.
def get_matches(tournament)
    matches = {}
    base_point_value = tournament.base_point_value

    # Check that `match_values` in the config file is the right size.
    # The size must normally equal the number of matches.  However, if the
    # bracket is complete and it is double-elimination, then the array size may
    # be one larger than the number of matches, to account for a grand final
    # that was only one match long.
    num_matches = tournament.matches.size
    array_size = tournament.config[:match_values].size

    if num_matches != array_size
        if tournament.state != "complete" ||
           tournament.tournament_type != "double elimination" ||
           array_size != num_matches + 1
            raise "match_values in the config file is the wrong size." \
                    " The size is #{array_size}, expected #{num_matches}."
        end
    end

    tournament.matches.each do |match|
        s = OpenStruct.new(match[:match])
        points = tournament.config[:match_values][s.suggested_play_order - 1]

        puts "Match with play order #{s.suggested_play_order} has ID #{s.id}" \
               " and is worth #{points} points" \
               "#{" + #{base_point_value} base" if base_point_value > 0}"

        matches[s.id] = OpenStruct.new(state: s.state, play_order: s.suggested_play_order,
                                       attachment_count: s.attachment_count,
                                       team1: s.player1_id, team2: s.player2_id,
                                       winner_id: s.winner_id, loser_id: s.loser_id,
                                       points: points)
    end

    matches
end

# Returns a hash where each key is a team ID, and the corresponding value is an
# array of `OpenStruct`s that contains info about the players on that team.
def get_players(teams, tournament)
    players = {}

    # Parse the team list and create structs for each player on the teams.
    tournament.config[:teams].each do |team|
        team_id, _ = teams.find { |_, t| t.name == team[:name] }
        players[team_id] = []

        team[:players].each do |player|
            s = OpenStruct.new(player)
            players[team_id] << OpenStruct.new(name: s.name, scene: s.scene, points: 0.0)
            puts "Player #{s.name} from scene #{s.scene} is on team #{team[:name]}"
        end
    end

    # Bail out if any team doesn't have exactly 5 players.
    invalid_teams = players.select { |_, team| team.size != 5 }

    if invalid_teams.any?
        team_names = invalid_teams.keys.map { |id| teams[id].name }.join(", ")
        raise "These teams don't have 5 players: #{team_names}"
    end

    players
end

# Calculates how many points each team has earned in the tournament.
def calculate_team_points(tournament_info)
    # For each team, look at the matches that it is in, look at the point
    # values of those matches, and take the maximum point value.  That's the
    # number of points that the team has earned so far in the bracket.
    base_point_value = tournament_info.tournament.base_point_value

    tournament_info.teams.each do |team_id, team|
        matches_with_team = tournament_info.matches.select do |_, match|
            team_id == match.team1 || team_id == match.team2
        end

        puts "Team #{team.name} was in #{matches_with_team.size} matches"

        _, highest_value_match = matches_with_team.max_by { |_, match| match.points }
        points_earned = highest_value_match.points

        puts "The highest point values of those matches is #{points_earned}" \
               "#{" + #{base_point_value} base" if base_point_value > 0}"

        # Many matches have the same point value, but we care about the match
        # with the largest play_order.  That's the match that occured last, so
        # it's the farthest that the team advanced in the bracket.
        latest_match =
            matches_with_team.values.select { |match| match.points == points_earned }.
            max_by { |match| match.play_order }

        puts "The latest match with that score has play order #{latest_match.play_order}"

        team.points = points_earned + base_point_value

        # If the bracket is complete, and this is the last bracket of the
        # tournament, give this team one more point if they reached the last
        # match and won it.
        if latest_match.play_order == tournament_info.matches.size &&
           team_id == latest_match.winner_id &&
           tournament_info.tournament.final_bracket
            puts "This team gets 1 extra point for winning the tournament"
            team.points += 1
        end
    end
end

# Calculates how many points each player has earned in the tournament.
def calculate_player_points(tournament_info)
    tournament_info.teams.each do |team_id, team|
        tournament_info.players[team_id].each do |player|
            puts "Awarding #{team.points} points to player #{player.name} on team #{team.name}"
            player.points += team.points
        end
    end
end

# Calculates how many points each scene has earned in the tournament.
# Returns a hash whose keys are scene names, and whose values are the points
# that the scene has earned.
def calculate_scene_points(tournament_info)
    # Collect the scores of all players from the same scene.
    scene_scores = tournament_info.players.values.each_with_object({}) do |players, scores|
        players.each do |player|
            scores[player.scene] ||= []
            scores[player.scene] << player.points
        end
    end

    scene_scores.each_with_object({}) do |(scene, scores), results|
        # If a scene has more players than the max number of players whose scores
        # can be counted, drop the extra players' scores.
        # Sort the scores for each scene in descending order, so we only keep the
        # highest-scoring players.
        scores.sort! { |a, b| b <=> a }

        if scores.length > tournament_info.tournament.max_players_to_count
            dropped = scores.slice!(tournament_info.tournament.max_players_to_count..-1)

            puts "Dropping the #{dropped.size} lowest-scoring players from #{scene}," \
                   " scores: #{dropped.join(', ')}"
        end

        # Add up the scores for each scene.
        results[scene] = scores.sum
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
    output = calculate_points(read_tournament).map do |scene, points|
        OpenStruct.new(scene: scene, points: points)
    end.sort do |a, b|
        # Sort by points descending, then scene name ascending.
        a.points != b.points ? b.points <=> a.points : a.scene <=> b.scene
    end.map do |result|
        "#{result.scene} earned #{result.points} points"
    end

    puts output
end

if __FILE__ == $0
    main
end

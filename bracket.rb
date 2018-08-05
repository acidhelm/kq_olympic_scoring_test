# frozen_string_literal: true

class Bracket
    attr_accessor :teams, :players, :matches, :config

    def initialize(slug)
        @slug = slug

        url = "https://api.challonge.com/v1/tournaments/#{@slug}.json"
        params = { include_matches: 1, include_participants: 1 }

        response = send_get_request(url, "#{@slug}_tournament.json", params)
        @challonge_bracket = OpenStruct.new(response[:tournament])

        read_config
        read_teams
        read_matches
        read_players
    end

    protected

    def read_config
        # Find the match that has the config file attached to it.  By convention,
        # the file is attached to the first match, although we don't enforce that.
        # We just look for a match with exactly 1 attachment.
        first_match = @challonge_bracket.matches.select do |match|
            match[:match][:attachment_count] == 1
        end

        raise "No attachments were found in the bracket" if first_match.empty?
        raise "Multiple matches have an attachment" if first_match.size > 1

        # Read the options from the config file that's attached to that match.
        url = "https://api.challonge.com/v1/tournaments/#{@slug}/matches/" \
                "#{first_match[0][:match][:id]}/attachments.json"

        attachment_list = send_get_request(url, "#{@slug}_attachments.json")
        asset_url = attachment_list[0][:match_attachment][:asset_url]

        raise "Couldn't find the config file attachment" if asset_url.nil?

        uri = URI(asset_url)

        # The attachment URLs that Challonge returns don't have a scheme, and
        # instead start with "//".  Default to HTTPS.
        uri.scheme ||= "https"

        puts "Reading the config file from #{uri}"

        config = send_get_request(uri.to_s, "#{@slug}_config_file.json")

        %i(base_point_value final_bracket max_players_to_count match_values).each do |key|
            raise "The config file is missing \"#{key}\"" unless config.key?(key)
        end

        @config = OpenStruct.new
        @config.base_point_value = config[:base_point_value]
        @config.final_bracket = config[:final_bracket]
        @config.max_players_to_count = config[:max_players_to_count]
        @config.match_values = config[:match_values]
        @config.teams = config[:teams]
    end

    def read_teams
        @teams = []

        @challonge_bracket.participants.each do |team|
            @teams << Team.new(team[:participant])
        end

        puts "#{@teams.size} teams are in the bracket: " +
               @teams.sort_by(&:name).map { |t| %("#{t.name}") }.join(", ")
    end

    def read_matches
        # Check that `match_values` in the config file is the right size.
        # The size must normally equal the number of matches.  However, if the
        # bracket is complete and it is double-elimination, then the array size is
        # allowed to be one more than the number of matches, to account for a grand
        # final that was only one match long.
        #
        # If this is a two-stage bracket, the matches in the first stage have
        # `suggested_play_order` set to nil, so don't consider those matches.
        # If there is a match for 3rd place, its `suggested_play_order` is nil.
        # We also ignore that match, and instead, assign points to the 3rd-place
        # and 4th-place teams after the bracket has finished.
        @matches = []
        elim_stage_matches =
            @challonge_bracket.matches.select { |m| m[:match][:suggested_play_order] }
        num_matches = elim_stage_matches.size
        array_size = @config.match_values.size

        if num_matches != array_size
            if @challonge_bracket.state != "complete" ||
               @challonge_bracket.tournament_type != "double elimination" ||
               array_size != num_matches + 1
                raise "match_values in the config file is the wrong size." \
                        " The size is #{array_size}, expected #{num_matches}."
            end
        end

        elim_stage_matches.each do |match|
            @matches << Match.new(match[:match], @config.match_values)
        end

        @matches.sort_by!(&:play_order)
    end

    def read_players
        @players = {}

        # Parse the team list and create structs for each player on the teams.
        @config.teams.each do |team|
            # Look up the team in the `teams` hash.  This is how we associate a
            # team in the config file with its ID on Challonge.
            team_obj = @teams.find { |t| t.name.casecmp?(team[:name]) }

            # If the `find` call failed, then there is a team in the team list that
            # isn't in the bracket.  We allow this so that multiple brackets can
            # use the same master team list during a tournament.
            if team_obj.nil?
                puts "Skipping a team that isn't in the bracket: #{team[:name]}"
                next
            end

            @players[team_obj.id] = []

            team[:players].each do |player|
                @players[team_obj.id] << Player.new(player)
            end

            puts "#{team[:name]} (ID #{team_obj.id}) has: " +
                 @players[team_obj.id].map { |p| "#{p.name} (#{p.scene})" }.join(", ")
        end

        # Bail out if any team doesn't have exactly 5 players.
        invalid_teams = @players.select do |_, team|
            team.size != 5
        end.each_key.map do |team_id|
            @teams.find { |t| t.id == team_id }.name
        end

        if invalid_teams.any?
            raise "These teams don't have 5 players: #{invalid_teams.join(', ')}"
        end
    end

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
end

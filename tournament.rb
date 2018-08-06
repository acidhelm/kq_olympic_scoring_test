# frozen_string_literal: true

class Tournament
    attr_reader :brackets, :scenes, :scene_scores

    def initialize
        @brackets = []
        @scenes = {}
        @scene_scores = []
    end

    # Reads the Challonge bracket with the given slug, and fills in all the
    # data structures that represent that bracket.
    def load(slug)
        # TODO: Load the next bracket if there is one.
        bracket = Bracket.new(slug)
        @brackets << bracket

        bracket.players.each_value do |team|
            team.each do |player|
                @scenes[player.scene] ||= []
                @scenes[player.scene] << player
            end
        end

        scene_list = @scenes.map do |scene, players|
            "Scene #{scene} has #{players.size} players: " +
              players.map(&:name).join(", ")
        end

        puts scene_list
    end

    def calculate_points
        @brackets.each do |bracket|
            bracket.calculate_team_points
            bracket.calculate_player_points
        end

        calculate_scene_points
    end

    protected

    # Calculates how many points each scene has earned in the tournament.
    # Sets `@scene_scores` to an array of `Scene` objects.
    def calculate_scene_points
        # Collect the scores of all players from the same scene.  Since a player
        # may be in multiple brackets, we find their greatest score across
        # all brackets.
        # `player_scores` is a hash from a Player object's hash to the Player object.
        # This is a hash to make lookups easier; the keys aren't used after
        # this loop.
        player_scores = @brackets.each_with_object({}) do |bracket, scores|
            bracket.players.each_value do |team_players|
                team_players.each do |player|
                    key = player.hash

                    if !scores.key?(key) || player.points > scores[key].points
                        scores[key] = player
                    end
                end
            end
        end

        # Assemble the scores from the players in each scene.  `scene_scores`
        # is a hash from a scene name to an array that holds the scores of all
        # the players in that scene.
        scene_scores = player_scores.each_value.each_with_object({}) do |player, scores|
            scores[player.scene] ||= []
            scores[player.scene] << player.points
        end

        @scene_scores = scene_scores.map do |scene, scores|
            # If a scene has more players than the max number of players whose
            # scores can be counted, drop the extra players' scores.
            # Sort the scores for each scene in descending order, so we only
            # keep the highest scores.
            max_players_to_count = @brackets[0].config.max_players_to_count
            scores.sort!.reverse!

            if scores.size > max_players_to_count
                dropped = scores.slice!(max_players_to_count..-1)

                puts "Dropping the #{dropped.size} lowest scores from #{scene}:" +
                     dropped.join(", ")
            end

            # Add up the scores for this scene.
            Scene.new(scene, scores)
        end
    end
end

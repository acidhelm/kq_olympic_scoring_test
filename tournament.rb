# frozen_string_literal: true

class Tournament
    attr_reader :brackets, :scenes

    def initialize
        @brackets = []
        @scenes = {}
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
            # bracket.calculate_scene_points
        end
    end
end

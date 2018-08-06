# frozen_string_literal: true

class Scene
    attr_accessor :name, :score, :num_players

    def initialize(name, player_scores)
        @name = name
        @score = player_scores.sum
        @num_players = player_scores.size
    end
end

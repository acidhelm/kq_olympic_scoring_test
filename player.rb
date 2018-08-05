# frozen_string_literal: true

class Player
    attr_reader :name, :scene, :points

    def initialize(config_obj)
        @name = config_obj[:name]
        @scene = config_obj[:scene]
        @points = 0.0
    end
end

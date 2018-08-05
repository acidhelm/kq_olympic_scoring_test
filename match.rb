# frozen_string_literal: true

class Match
    attr_reader :id, :state, :play_order, :team1_id, :team2_id, :points

    def initialize(challonge_obj, match_values)
        @id = challonge_obj[:id]
        @state = challonge_obj[:state]
        @play_order = challonge_obj[:suggested_play_order]
        @team1_id = challonge_obj[:player1_id]
        @team2_id = challonge_obj[:player2_id]
        @points = match_values[@play_order - 1]
    end
end

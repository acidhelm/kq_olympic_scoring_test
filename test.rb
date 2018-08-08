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


def main
    tournament = Tournament.new

    if tournament.load(SLUG)
        tournament.calculate_points
        puts tournament.scene_scores.sort
    else
        puts "No brackets were loaded."
    end
end

if __FILE__ == $0
    main
end

# frozen_string_literal: true

require "dotenv/load"
require "json"
require "optparse"
require "rest-client"
require_relative "bracket"
require_relative "config"
require_relative "match"
require_relative "player"
require_relative "scene"
require_relative "team"
require_relative "tournament"

Options = Struct.new(:tournament_name, :api_key, :use_cache, :update_cache) do
    def initialize
        # Set up defaults.  The tournament name and API key members default to
        # values in ENV, to stay compatible with the old method of always reading
        # those strings from ENV.
        self.tournament_name = ENV["CHALLONGE_SLUG"]
        self.api_key = ENV["CHALLONGE_API_KEY"]
        self.use_cache = false
        self.update_cache = false
    end
end

def parse_command_line
    options = Options.new

    parser = OptionParser.new do |p|
        script_name = File.basename $0

        p.banner = "Usage: #{script_name} -t tournament_name [-a api_key] [-c] [-u]"

        p.on("-t", "--tournament SLUG_OR_ID", "The slug or Challonge ID of the tournament") do |value|
            options.tournament_name = value
        end

        p.on("-a", "--api-key API_KEY", "Your Challonge API key") do |value|
            options.api_key = value
        end

        p.on("-c", "--use-cache", "Use cached HTTP responses") do |value|
            options.use_cache = value
        end

        p.on("-u", "--update-cache", "Update the cached HTTP responses") do |value|
            options.update_cache = value
        end

        p.on_tail("-h", "--help", "Print this help") do
            $stderr.puts p
            exit 0
        end
    end

    # Parse the command line.
    parser.parse ARGV

    # Check that we have a tournament name and API key.
    if options.tournament_name.nil?
        $stderr.puts "No tournament name was specified", parser
        exit 1
    end

    if options.api_key.nil?
        $stderr.puts "No API key was specified", parser
        exit 1
    end

    options
end

def main
    tournament = Tournament.new(parse_command_line)

    if tournament.load
        tournament.calculate_points
        puts tournament.scene_scores.sort
    else
        puts "No brackets were loaded."
    end
end

if __FILE__ == $0
    main
end

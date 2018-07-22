This is an initial test implementation of the scene-wide scoring system that will be used for BB3.
The idea is outlined in [this Facebook post](https://www.facebook.com/events/1788575457853671/permalink/1949400981771117) in the BB3 group.

To run this test, clone the repo and create a file named `.env` in the source
directory with this content:

```
CHALLONGE_API_KEY=your_challonge_api_key
CHALLONGE_SLUG="tvtpeasf"
```

That is a simple 4-team tournament that demonstrates the calculations that
the script does.  Run the script with:

```
bundle exec ruby test.rb
```

The script prints a lot of debug output, but at the end, it prints how many
points each scene earned.

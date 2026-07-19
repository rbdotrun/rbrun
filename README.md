# Rbrun
Short description and motivation.

## Usage
How to use my plugin.

## Installation

Add rbrun to your application's Gemfile:

```ruby
gem "rbrun", github: "rbdotrun/rbrun"
```

```bash
$ bundle
```

That's the whole install. rbrun is internally composed of two provider sub-gems (`rbrun-sandbox`,
`rbrun-runtime`, under `gems/`), but the engine **vendors** them — it packages their code and puts it
on its load path — so the host installs a single gem with no extra Gemfile lines and nothing to
publish. The sub-gems keep their own gemspecs and stay independently publishable, should that ever be
wanted; consuming rbrun never requires it.

## Contributing
Contribution directions go here.

## License
The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

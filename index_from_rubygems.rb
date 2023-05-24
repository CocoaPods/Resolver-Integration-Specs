#!/usr/bin/env ruby

require 'json'
require 'open-uri'
require 'set'
require 'bundler/compact_index_client/gem_parser'

GEMS = %w(inspec).freeze
EXCLUDED_GEMS = %w(yaml-safe_load_stream2 yaml-safe_load_stream yaml-safe_load_stream3 recursive-open-struct yajl-ruby excon hashdiff jsonpath dry-configurable dry-struct dry-types inspec-core train-aws train-habitat train-winrm train faraday_middleware rake mongo progress_bar rake cookstyle activesupport).freeze
EXCLUDED_GEM_VERSIONS = {}.freeze

VERSION_PATTERN = /\A
  [0-9]+\.[0-9]+\.[0-9]+           (?# Number component)
  ([-][0-9a-z-]+(\.[0-9a-z-]+)*)?  (?# Pre-release component)
  ([+][0-9a-z-]+(\.[0-9a-z-]+)*)?  (?# Build component)
    \Z/xi

def coerce_to_semver(version)
  return version if version.sub(/^(\S+\s+)/, '') =~ VERSION_PATTERN
  return "#{Regexp.last_match[1]}#{Regexp.last_match[2]}" if version =~ /^(\S+\s+)? (\d+\.\d+\.\d+) (?: \.\d+)*$/ix

  parts = version.split(/[\.-]/, 4)
  4.times do |i|
    if parts[i] =~ /-?([a-zA-Z])/
      parts << '0' until parts.size >= 3
      parts[i].sub!(/-?([a-zA-Z]+)/, '')
      parts[i] = '0' if parts[i].empty?
      parts[3] = Regexp.last_match[1] + parts[i..-1].join('')
    end
  end
  semver = parts[0..2].join('.')
  semver.sub!(/([a-zA-Z])/, '-\1')
  semver += '-' + parts[-1] if parts.size > 3
  semver.chomp(".")
end

def coerce_dependencies_to_semver(deps)
  dependencies = {}
  deps.sort_by(&:first).each do |name, reqs|
    dependencies[name] = reqs.map { |r| coerce_to_semver(r) }.join(',')
  end
  dependencies
end

gems = Set.new(GEMS)
downloaded_gems = Set.new
specs = []
parser = Bundler::CompactIndexClient::GemParser.new

loop do
  size = gems.size
  (gems ^ downloaded_gems).each do |g|
    next if EXCLUDED_GEMS.include?(g)

    if g == "ruby"
      specs << { "name" => g, "number" => Gem.ruby_version.to_s, "dependencies" => [] }
    elsif g == "rubygems"
      specs << { "name" => g, "number" => Gem::VERSION, "dependencies" => [] }
    else
      URI.open("https://rubygems.org/info/#{g}") do |f|
        f.each_line do |line|
          next if line == "---\n"

          version, platform, dependencies, meta_dependencies = parser.parse(line)
          next unless platform.nil?

          excluded_versions = EXCLUDED_GEM_VERSIONS[g] || []
          next if excluded_versions.include?(version)

          meta_dependencies.each do |name, reqs|
            if %w(ruby rubygems).include?(name)
              dependencies << [name, reqs.map(&:strip)]
            end
          end

          dependencies.reject! {|d| EXCLUDED_GEMS.include?(d.first) }

          gems.merge(specs.flat_map { |s| dependencies.map(&:first) })
          specs << { "name" => g, "number" => version, "dependencies" => dependencies }
        end
      end
    end

    downloaded_gems.add(g)
  end

  break if gems.size == size
end

specs.uniq! { |s| [s['name'], s['number']] }
specs.sort_by! { |s| s['name'].downcase }
specs = specs.group_by { |s| s['name'] }.values.map do |spec|
  [spec.first['name'], spec.flat_map do |s|
    {
      'name' => s['name'],
      'version' => coerce_to_semver(s['number']),
      'dependencies' => coerce_dependencies_to_semver(s['dependencies'])
    }
  end.uniq { |s| s['version'] }.sort_by { |s| Gem::Version.new(s['version']) }
  ]
end

specs = Hash[specs]

json = JSON.generate(specs)

File.open("index/rubygems-#{Date.today}.json", 'w') { |f| f.write json }

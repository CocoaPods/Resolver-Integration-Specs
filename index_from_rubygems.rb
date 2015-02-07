#!/usr/bin/env ruby

require 'json'
require 'open-uri'
require 'set'

VERSION_PATTERN = /\A
	[0-9]+\.[0-9]+\.[0-9]+           (?# Number component)
	([-][0-9a-z-]+(\.[0-9a-z-]+)*)?  (?# Pre-release component)
	([+][0-9a-z-]+(\.[0-9a-z-]+)*)?  (?# Build component)
    \Z/xi

def coerce_to_semver(version)
	return version if version.sub(/^(\S+\s+)/, '') =~ VERSION_PATTERN
	return "#{$1}#{$2}" if version =~ /^(\S+\s+)? (\d+\.\d+\.\d+) (?: \.\d+)*$/ix

	parts = version.split(/[\.-]/, 4)
	4.times do |i|
		if parts[i] =~ /-?([a-zA-Z])/
			until parts.size >= 3; parts << '0'; end
			parts[i].	sub!(/-?([a-zA-Z]+)/, '')
			parts[i] = '0' if parts[i].empty?
			parts[3] = $1 + parts[i..-1].join('')
		end
	end
	semver = parts[0..2].join('.')
	semver.sub!(/([a-zA-Z])/, '-\1')
	semver += '-' + parts[-1] if parts.size > 3
	semver
end

def coerce_dependencies_to_semver(deps)
	dependencies = {}
	deps.each do |name, req|
		dependencies[name] = req.split(',').map { |r| coerce_to_semver(r) }.join(',')
	end
	dependencies
end

gems = Set.new(%w(rails capybara bundler))
downloaded_gems = Set.new
specs = []

begin
	size = gems.size
	(gems ^ downloaded_gems).each_slice(200) do |g|
		specs += JSON.load open("http://bundler.rubygems.org/api/v1/dependencies.json?gems=#{g.join(',')}")
	end
	downloaded_gems.merge(gems)

	gems.merge(specs.flat_map { |s| s['dependencies'].map(&:first) })
end while gems.size != size

specs.reject! { |s| s['platform'] != 'ruby' }
specs.uniq! { |s| [s['name'], s['number']] }
specs.sort_by! { |s| s['name'].downcase }
specs = specs.group_by { |s| s['name'] }.values.map do |spec|
	[spec.first['name'], spec.flat_map do |s|
		{
			'name' => s['name'],
			'version' => coerce_to_semver(s['number']),
			'dependencies' => coerce_dependencies_to_semver(Hash[s['dependencies']])
		}
	end.uniq { |s| s['version'] }.sort_by { |s| Gem::Version.new(s['version']) }
	]
end

specs = Hash[specs]

json = JSON.pretty_generate(specs)

File.open('index/rubygems.json', 'w') { |f| f.write json }

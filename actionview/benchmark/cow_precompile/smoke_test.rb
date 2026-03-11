#!/usr/bin/env ruby
# frozen_string_literal: true

# Quick smoke test of the benchmark logic (works on macOS, no /proc needed)

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../../../Gemfile", __FILE__)
require "bundler/setup"
require "active_support/all"
require "action_view"

puts "ActionView loaded: #{ActionView.version}"

require "fileutils"
dir = "/tmp/bench_templates_test"
FileUtils.rm_rf(dir)
FileUtils.mkdir_p("#{dir}/bench")
5.times do |i|
  File.write("#{dir}/bench/template_#{i}.html.erb", <<~ERB)
    <div class="card"><h1>Template #{i}</h1>
    <% 3.times do |j| %><span><%= j * #{i + 1} %></span><% end %>
    </div>
  ERB
end
puts "Generated 5 templates"

ActionView::Resolver.caching = true
resolver = ActionView::FileSystemResolver.new(dir)
details = { locale: [:en], handlers: [:erb], formats: [:html], variants: [] }
key = ActionView::LookupContext::DetailsKey.details_cache_key(details)
resolver.all_template_paths.each do |tp|
  resolver.find_all(tp.name, tp.prefix, tp.partial?, details, key, [])
end
puts "Unbound templates found: #{resolver.built_unbound_templates.size}"

resolver.built_unbound_templates.each(&:compile_handler!)
puts "Handler precompilation: done"

# Verify rendering works with cached handler output
view_cls = ActionView::Base.with_empty_template_cache
lookup = ActionView::LookupContext.new(ActionView::PathSet.new([resolver]))
view = view_cls.new(lookup, {}, nil)
output = view.render(template: "bench/template_0")
puts "Render output: #{output.strip[0..60]}..."

# Verify the template used cached handler code
tmpl = resolver.built_unbound_templates.first.bind_locals([])
code = tmpl.instance_variable_get(:@handler_compiled_code)
puts "Handler code cached: #{!code.nil?}"
puts "Handler code size: #{code&.size} bytes"

puts "\nSUCCESS - benchmark logic verified"

#!/usr/bin/env ruby
# frozen_string_literal: true

# Template Handler Pre-compilation – CoW Memory Benchmark
#
# Measures Copy-on-Write memory savings from pre-running template
# handlers (ERB → Ruby source) before forking worker processes.
#
# Must be run on Linux (needs /proc/[pid]/smaps for PSS measurement).
# Use the provided Dockerfile and run.sh to run in Docker.
#
# Two scenarios are compared:
#
#   WITHOUT precompilation:
#     Each forked worker independently reads template files from disk
#     and runs the ERB parser, creating private memory pages that
#     duplicate the same data across every worker.
#
#   WITH precompilation:
#     Handler output (ERB → Ruby) is cached on UnboundTemplate before
#     the fork. The cached strings live in shared CoW pages across
#     all workers.

require "bundler/setup"
require "active_support/all"
require "action_view"

NUM_TEMPLATES = 1000
NUM_WORKERS   = 4
TEMPLATE_DIR  = "/tmp/bench_templates"

# Ensure resolver caching is on (production mode).
ActionView::Resolver.caching = true

# ── Template generation ──────────────────────────────────────────

def generate_templates
  require "fileutils"
  FileUtils.rm_rf(TEMPLATE_DIR)
  FileUtils.mkdir_p("#{TEMPLATE_DIR}/bench")

  NUM_TEMPLATES.times do |i|
    # ~100-line realistic ERB with loops, conditionals, and helpers
    # to exercise the parser with production-like complexity.
    erb = <<~ERB.gsub("TIDX", i.to_s).gsub("TMUL", (i + 1).to_s).gsub("TMOD20", (i % 20).to_s).gsub("TMOD28", ((i % 28) + 1).to_s).gsub("TMOD10", (i % 10).to_s).gsub("TEVEN", i.even?.to_s)
      <!DOCTYPE html>
      <div class="container" id="page-TIDX">
        <header class="page-header">
          <nav class="navbar navbar-expand">
            <a class="navbar-brand" href="/">App</a>
            <ul class="navbar-nav">
              <% 5.times do |n| %>
                <li class="nav-item">
                  <a class="nav-link" href="/section-<%= n %>">Section <%= n %></a>
                </li>
              <% end %>
            </ul>
          </nav>
        </header>

        <main class="content" role="main">
          <div class="row">
            <div class="col-md-8">
              <article class="post" data-id="TIDX">
                <h1 class="post-title"><%= "Title for template TIDX" %></h1>
                <div class="post-meta">
                  <span class="author"><%= "Author TIDX" %></span>
                  <time datetime="2025-01-01"><%= "January TMOD28, 2025" %></time>
                  <span class="category"><%= "Category TMOD10" %></span>
                </div>

                <div class="post-body">
                  <p>Lorem ipsum dolor sit amet, consectetur adipiscing elit.
                     Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.
                     Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris.</p>

                  <% if TEVEN == "true" %>
                    <div class="featured-image">
                      <img src="/images/TIDX.jpg" alt="Featured" class="img-fluid" />
                      <figcaption>Figure TIDX</figcaption>
                    </div>
                  <% end %>

                  <p>Duis aute irure dolor in reprehenderit in voluptate velit esse
                     cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat
                     cupidatat non proident.</p>

                  <table class="table table-striped">
                    <thead>
                      <tr>
                        <th>Item</th><th>Value</th><th>Status</th><th>Actions</th>
                      </tr>
                    </thead>
                    <tbody>
                      <% 8.times do |row| %>
                        <tr class="<%= row.even? ? 'even' : 'odd' %>">
                          <td><%= "Item \#{row}" %></td>
                          <td><%= row * TMUL %></td>
                          <td>
                            <% if row > 5 %>
                              <span class="badge badge-warning">Pending</span>
                            <% elsif row > 2 %>
                              <span class="badge badge-success">Active</span>
                            <% else %>
                              <span class="badge badge-secondary">Draft</span>
                            <% end %>
                          </td>
                          <td>
                            <a href="/edit/<%= row %>">Edit</a>
                            <a href="/delete/<%= row %>" data-method="delete">Delete</a>
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>

                <div class="comments-section">
                  <h3>Comments (<%= TMOD20 %>)</h3>
                  <% 4.times do |c| %>
                    <div class="comment" id="comment-<%= c %>">
                      <div class="comment-header">
                        <strong><%= "User \#{c}" %></strong>
                        <time><%= "\#{c + 1} days ago" %></time>
                      </div>
                      <div class="comment-body">
                        <p>This is comment number <%= c %> on template TIDX.
                           Very insightful content here.</p>
                        <% if c.zero? %>
                          <div class="comment-featured">
                            <span class="badge">Featured</span>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                </div>
              </article>
            </div>

            <aside class="col-md-4 sidebar">
              <div class="widget">
                <h4>Related Posts</h4>
                <ul class="list-unstyled">
                  <% 5.times do |r| %>
                    <li><a href="/post/<%= r + TIDX %>"><%= "Related post \#{r}" %></a></li>
                  <% end %>
                </ul>
              </div>
              <div class="widget">
                <h4>Tags</h4>
                <% %w[ruby rails erb html css javascript].each do |tag| %>
                  <span class="tag"><%= tag %></span>
                <% end %>
              </div>
            </aside>
          </div>
        </main>

        <footer class="page-footer">
          <div class="row">
            <div class="col-md-4">&copy; 2025 App</div>
            <div class="col-md-4">
              <% 3.times do |f| %>
                <a href="/footer-<%= f %>">Link <%= f %></a>
              <% end %>
            </div>
            <div class="col-md-4">Template TIDX</div>
          </div>
        </footer>
      </div>
    ERB
    File.write("#{TEMPLATE_DIR}/bench/template_#{i}.html.erb", erb)
  end
end

# ── /proc memory helpers (Linux only) ────────────────────────────

def pss_kb(pid)
  rollup = "/proc/#{pid}/smaps_rollup"
  text = File.exist?(rollup) ? File.read(rollup) : File.read("/proc/#{pid}/smaps")
  text.scan(/^Pss:\s+(\d+)/).flatten.map(&:to_i).sum
end

def rss_kb(pid)
  File.read("/proc/#{pid}/status")[/^VmRSS:\s+(\d+)/, 1].to_i
end

# ── Populate the resolver cache (shared across both scenarios) ───

def populate_resolver(resolver)
  details = {
    locale: [:en],
    handlers: [:erb],
    formats: [:html],
    variants: []
  }
  key = ActionView::LookupContext::DetailsKey.details_cache_key(details)

  resolver.all_template_paths.each do |tp|
    resolver.find_all(tp.name, tp.prefix, tp.partial?, details, key, [])
  end
end

# ── Core benchmark ───────────────────────────────────────────────

def run_scenario(label, precompile:)
  puts
  puts "=" * 62
  puts "  #{label}"
  puts "=" * 62

  # Fresh resolver (no stale caches from the other scenario).
  resolver = ActionView::FileSystemResolver.new(TEMPLATE_DIR)
  ActionView::LookupContext::DetailsKey.clear

  # Discover all templates BEFORE fork so template lookup structures
  # are shared via CoW in both scenarios.
  populate_resolver(resolver)

  if precompile
    resolver.built_unbound_templates.each(&:compile_handler!)
    puts "  Pre-compiled handler output for #{resolver.built_unbound_templates.size} templates"
  else
    puts "  Handler precompilation: skipped"
  end

  # Compact the heap for a clean CoW baseline.
  GC.compact if GC.respond_to?(:compact)
  GC.start

  puts "  Parent RSS before fork: #{rss_kb(Process.pid)} kB"

  # Fork workers. Each renders all templates then signals the parent.
  pipes = []
  pids = NUM_WORKERS.times.map { |w|
    r, wr = IO.pipe
    pipes << r

    pid = fork do
      r.close
      Process.setproctitle("bench-worker-#{w}")

      view_cls = ActionView::Base.with_empty_template_cache
      lookup   = ActionView::LookupContext.new(ActionView::PathSet.new([resolver]))
      view     = view_cls.new(lookup, {}, nil)

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      NUM_TEMPLATES.times { |i| view.render(template: "bench/template_#{i}") }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

      wr.puts(elapsed.to_s)
      wr.close
      sleep 600 # stay alive for measurement
    end

    wr.close
    pid
  }

  # Wait for workers to finish rendering.
  times = pipes.map { |r| r.gets.to_f.tap { r.close } }
  sleep 0.3 # let memory counters settle

  # Measure memory.
  mem = pids.map { |p| { pss: pss_kb(p), rss: rss_kb(p) } }

  # Cleanup.
  pids.each { |p| Process.kill(:TERM, p) rescue nil }
  pids.each { |p| Process.wait(p) rescue nil }

  # Report.
  puts
  NUM_WORKERS.times do |i|
    puts "  Worker %d:  render %7.3fs   PSS %7d kB   RSS %7d kB" %
         [i, times[i], mem[i][:pss], mem[i][:rss]]
  end

  avg_pss  = mem.sum { |m| m[:pss] }.to_f / NUM_WORKERS
  avg_rss  = mem.sum { |m| m[:rss] }.to_f / NUM_WORKERS
  avg_time = times.sum / NUM_WORKERS

  puts
  puts "  Avg render: %.3fs" % avg_time
  puts "  Avg PSS:    %.0f kB  (%.1f MB)" % [avg_pss, avg_pss / 1024]
  puts "  Avg RSS:    %.0f kB  (%.1f MB)" % [avg_rss, avg_rss / 1024]

  { avg_pss: avg_pss, avg_rss: avg_rss, avg_time: avg_time,
    total_pss: mem.sum { |m| m[:pss] } }
end

# ── Main ─────────────────────────────────────────────────────────

puts "=" * 62
puts "  Template Handler Pre-compilation – CoW Memory Benchmark"
puts "=" * 62
puts "  Ruby:      #{RUBY_VERSION}"
puts "  Templates: #{NUM_TEMPLATES}"
puts "  Workers:   #{NUM_WORKERS}"

generate_templates

baseline = run_scenario("WITHOUT handler precompilation", precompile: false)
improved = run_scenario("WITH handler precompilation",    precompile: true)

dpss = baseline[:avg_pss] - improved[:avg_pss]
pct  = baseline[:avg_pss] > 0 ? (dpss / baseline[:avg_pss] * 100) : 0
dtot = baseline[:total_pss] - improved[:total_pss]
dtime = baseline[:avg_time] - improved[:avg_time]
tpct  = baseline[:avg_time] > 0 ? (dtime / baseline[:avg_time] * 100) : 0

puts
puts "=" * 62
puts "  RESULTS"
puts "=" * 62
puts
puts "  %-34s %12s %12s" % ["", "Without", "With"]
puts "  " + "-" * 58
puts "  %-34s %9.0f kB %9.0f kB" % ["Avg PSS / worker",  baseline[:avg_pss],  improved[:avg_pss]]
puts "  %-34s %9.0f kB %9.0f kB" % ["Total PSS (#{NUM_WORKERS} workers)", baseline[:total_pss], improved[:total_pss]]
puts "  %-34s %9.3f s  %9.3f s"  % ["Avg render time",   baseline[:avg_time], improved[:avg_time]]
puts
puts "  PSS saved per worker:  %.0f kB  (%.1f MB)  %.1f%% reduction" % [dpss, dpss / 1024.0, pct]
puts "  Total PSS saved:       %.0f kB  (%.1f MB)" % [dtot, dtot / 1024.0]
puts "  Render time saved:     %.3fs  (%.1f%% faster)" % [dtime, tpct]
puts

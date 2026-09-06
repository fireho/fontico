# frozen_string_literal: true

# Only when someone is watching: a colour escape in a CI log or a piped file
# is noise, and the message reads fine without it.
def fontico_red(text) = $stdout.tty? ? "\e[31m#{text}\e[0m" : text

def fontico_print_report(report)
  puts "fontico: #{report.written.size} artifact(s)"
  report.written.each { puts "  #{_1}" }
  puts "  fetched #{report.fetched.size}, cached #{report.cached.size}"

  # Loud, but not fatal: one bad name should not stop the other 199 icons
  # from building. The artifacts simply come out without it.
  if report.missing&.any?
    puts
    puts fontico_red("fontico: #{report.missing.size} icon(s) could not be resolved and were left out:")
    report.missing.each { |name, reason| puts fontico_red("  #{name}: #{reason}") }
    puts fontico_red("  fix the entry in icons.yml, then run rake fontico:build again")
    puts
  end

  report.skipped.each do |target, names|
    puts "  #{target}: skipped #{names.size} multicolor icon(s): #{names.join(", ")}" if names.any?
  end
  puts "  pending target(s): #{report.pending.join(", ")}" if report.pending.any?

  if report.warnings.any?
    puts "\nfontico: #{report.warnings.size} icon(s) need fixing at the source:"
    report.warnings.each { |name, list| puts "  #{name}: #{list.join("; ")}" }
    puts "  see docs/icon-authoring.html"
  end
end

namespace :fontico do
  desc "Build icon artifacts from icons.yml"
  task :build do
    require "fontico"
    fontico_print_report(Fontico.build)
  end

  desc "Re-fetch every icon from its provider. Codepoints stay pinned."
  task :update do
    require "fontico"
    fontico_print_report(Fontico.build(force: true))
  end
end

# Deploys just work: Propshaft serves whatever is in app/assets/builds, and
# that directory is gitignored in a stock Rails app, so the artifacts have to
# be regenerated during precompile rather than committed.
#
# Same hook jsbundling-rails uses for javascript:build.
if Rake::Task.task_defined?("assets:precompile")
  Rake::Task["assets:precompile"].enhance(["fontico:build"])
end

if Rake::Task.task_defined?("assets:clobber")
  Rake::Task["assets:clobber"].enhance(["fontico:clobber"])
end

namespace :fontico do
  desc "Remove generated icon artifacts (icons.lock is kept: it is source)"
  task :clobber do
    require "fontico"
    %w[icons.svg icons.css icons.ttf].each do |name|
      path = File.join(Fontico.root, Fontico.output_dir, name)
      File.delete(path) if File.exist?(path)
    end
  end
end

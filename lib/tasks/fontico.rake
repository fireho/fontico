# frozen_string_literal: true

namespace :fontico do
  desc "Build icon artifacts from icons.yml"
  task :build do
    require "fontico"
    report = Fontico.build

    puts "fontico: #{report.written.size} artifact(s)"
    report.written.each { puts "  #{_1}" }
    puts "  fetched #{report.fetched.size}, cached #{report.cached.size}"

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

  desc "Re-fetch every icon, ignoring icons.lock"
  task :update do
    require "fontico"
    File.delete(File.join(Fontico.root, "icons.lock")) if File.exist?(File.join(Fontico.root, "icons.lock"))
    Rake::Task["fontico:build"].invoke
  end
end

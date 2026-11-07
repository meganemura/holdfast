# Runs every test file: `ruby -Ilib test/run.rb`.
Dir.glob(File.join(__dir__, "*_test.rb")).sort.each { require _1 }

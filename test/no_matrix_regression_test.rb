require_relative "test_helper"

# Matrix was retired in the SP4 journal-only migration. This guard keeps it
# from creeping back into the product surface (docs/superpowers history is
# exempt — those documents describe the migration itself).
class NoMatrixRegressionTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  SCANNED = %w[lib bin templates setup.rb install.sh config.example.yml].freeze
  # "matron" contains no "matrix"; allow nothing...
  PATTERN = /matrix/i.freeze
  # ...except config.rb, whose MATRIX_RETIRED rejection of the old schema
  # must, by definition, name the thing it rejects.
  EXEMPT_FILES = %w[lib/dev_boxer/config.rb].freeze

  def test_no_matrix_references_outside_migration_docs
    offenders = []
    SCANNED.each do |entry|
      path = File.join(ROOT, entry)
      files = File.directory?(path) ? Dir.glob(File.join(path, "**", "*")).select { |f| File.file?(f) } : [path]
      files.each do |file|
        next if EXEMPT_FILES.any? { |exempt| file.end_with?(exempt) }
        File.foreach(file).with_index(1) do |line, number|
          offenders << "#{file}:#{number}: #{line.strip}" if line.match?(PATTERN)
        end
      end
    end
    assert_empty offenders, "Matrix references found:\n#{offenders.join("\n")}"
  end
end

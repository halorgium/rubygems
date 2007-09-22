require 'test/unit'
require 'test/gemutilities'
require 'rubygems/indexer'
require 'rubygems/commands/mirror_command'

class TestGemCommandsMirrorCommand < RubyGemTestCase

  def setup
    super

    @cmd = Gem::Commands::MirrorCommand.new
  end

  def test_execute
    util_make_gems

    gems_dir = File.join @tempdir, 'gems'
    mirror = File.join @tempdir, 'mirror'

    FileUtils.mkdir_p gems_dir
    FileUtils.mkdir_p mirror

    Dir[File.join(@gemhome, 'cache', '*.gem')].each do |gem|
      FileUtils.mv gem, gems_dir
    end

    use_ui @ui do
      Gem::Indexer.new(@tempdir).generate_index
    end

    orig_HOME = ENV['HOME']
    ENV['HOME'] = @tempdir
    Gem.instance_variable_set :@user_home, nil

    File.open File.join(Gem.user_home, '.gemmirrorrc'), 'w' do |fp|
      fp.puts "---"
      fp.puts "- from: file://#{@tempdir}"
      fp.puts "  to: #{mirror}"
    end

    use_ui @ui do
      @cmd.execute
    end

    assert File.exist?(File.join(mirror, 'gems', "#{@a0_0_1.full_name}.gem"))
    assert File.exist?(File.join(mirror, 'gems', "#{@a0_0_2.full_name}.gem"))
    assert File.exist?(File.join(mirror, 'gems', "#{@b0_0_2.full_name}.gem"))
    assert File.exist?(File.join(mirror, 'gems', "#{@c1_2.full_name}.gem"))
    assert File.exist?(File.join(mirror, 'yaml'))
  ensure
    orig_HOME.nil? ? ENV.delete('HOME') : ENV['HOME'] = orig_HOME
    Gem.instance_variable_set :@user_home, nil
  end

end

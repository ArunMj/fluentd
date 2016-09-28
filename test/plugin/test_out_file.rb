require_relative '../helper'
require 'fluent/test/driver/output'
require 'fluent/plugin/out_file'
require 'fileutils'
require 'time'

class FileOutputTest < Test::Unit::TestCase
  def setup
    Fluent::Test.setup
    FileUtils.rm_rf(TMP_DIR)
    FileUtils.mkdir_p(TMP_DIR)
  end

  TMP_DIR = File.expand_path(File.dirname(__FILE__) + "/../tmp/out_file#{ENV['TEST_ENV_NUMBER']}")
  SYMLINK_PATH = File.expand_path("#{TMP_DIR}/current")

  CONFIG = %[
    path #{TMP_DIR}/out_file_test
    compress gz
    utc
  ]

  def create_driver(conf = CONFIG)
    Fluent::Test::Driver::Output.new(Fluent::Plugin::FileOutput).configure(conf)
  end

  sub_test_case 'configuration' do
    test 'basic configuration' do
      d = create_driver %[
        path test_path
        compress gz
      ]
      assert_equal 'test_path', d.instance.path
      assert_equal :gz, d.instance.compress
      assert_equal :gzip, d.instance.instance_eval{ @compress_method }
    end

    test 'path should be writable' do
      assert_nothing_raised do
        create_driver %[path #{TMP_DIR}/test_path]
      end

      assert_nothing_raised do
        FileUtils.mkdir_p("#{TMP_DIR}/test_dir")
        File.chmod(0777, "#{TMP_DIR}/test_dir")
        create_driver %[path #{TMP_DIR}/test_dir/foo/bar/baz]
      end

      assert_raise(Fluent::ConfigError) do
        FileUtils.mkdir_p("#{TMP_DIR}/test_dir")
        File.chmod(0555, "#{TMP_DIR}/test_dir")
        create_driver %[path #{TMP_DIR}/test_dir/foo/bar/baz]
      end
    end

    test 'default timezone is localtime' do
      d = create_driver(%[path #{TMP_DIR}/out_file_test])
      time = event_time("2011-01-02 13:14:15 UTC")

      with_timezone(Fluent.windows? ? 'NST-8' : 'Asia/Taipei') do
        d.run(default_tag: 'test') do
          d.feed(time, {"a"=>1})
        end
      end
      assert_equal 1, d.formatted.size
      assert_equal %[2011-01-02T21:14:15+08:00\ttest\t{"a":1}\n], d.formatted[0]
    end
  end

  sub_test_case 'format' do
    test 'timezone UTC specified' do
      d = create_driver

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test') do
        d.feed(time, {"a"=>1})
        d.feed(time, {"a"=>2})
      end
      assert_equal 2, d.formatted.size
      assert_equal %[2011-01-02T13:14:15Z\ttest\t{"a":1}\n], d.formatted[0]
      assert_equal %[2011-01-02T13:14:15Z\ttest\t{"a":2}\n], d.formatted[1]
    end

    test 'time formatted with specified timezone, using area name' do
      d = create_driver %[
        path #{TMP_DIR}/out_file_test
        timezone Asia/Taipei
      ]

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test') do
        d.feed(time, {"a"=>1})
      end
      assert_equal 1, d.formatted.size
      assert_equal %[2011-01-02T21:14:15+08:00\ttest\t{"a":1}\n], d.formatted[0]
    end

    test 'time formatted with specified timezone, using offset' do
      d = create_driver %[
        path #{TMP_DIR}/out_file_test
        timezone -03:30
      ]

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test') do
        d.feed(time, {"a"=>1})
      end
      assert_equal 1, d.formatted.size
      assert_equal %[2011-01-02T09:44:15-03:30\ttest\t{"a":1}\n], d.formatted[0]
    end

    test 'configuration error raised for invalid timezone' do
      assert_raise(Fluent::ConfigError) do
        create_driver %[
          path #{TMP_DIR}/out_file_test
          timezone Invalid/Invalid
        ]
      end
    end
  end

  def check_gzipped_result(path, expect)
    # Zlib::GzipReader has a bug of concatenated file: https://bugs.ruby-lang.org/issues/9790
    # Following code from https://www.ruby-forum.com/topic/971591#979520
    result = ''
    File.open(path, "rb") { |io|
      loop do
        gzr = Zlib::GzipReader.new(io)
        result << gzr.read
        unused = gzr.unused
        gzr.finish
        break if unused.nil?
        io.pos -= unused.length
      end
    }

    assert_equal expect, result
  end

  sub_test_case 'write' do
    test 'basic case' do
      d = create_driver

      assert_false File.exist?("#{TMP_DIR}/out_file_test.20110102_0.log.gz")

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test') do
        d.feed(time, {"a"=>1})
        d.feed(time, {"a"=>2})
      end

      assert File.exist?("#{TMP_DIR}/out_file_test.20110102_0.log.gz")
      check_gzipped_result("#{TMP_DIR}/out_file_test.20110102_0.log.gz", %[2011-01-02T13:14:15Z\ttest\t{"a":1}\n] + %[2011-01-02T13:14:15Z\ttest\t{"a":2}\n])
    end
  end

  # sub_test_case 'file/directory permissions' do
  #   TMP_DIR_WITH_SYSTEM = File.expand_path(File.dirname(__FILE__) + "/../tmp/out_file_system#{ENV['TEST_ENV_NUMBER']}")
  #   # 0750 interprets as "488". "488".to_i(8) # => 4. So, it makes wrong permission. Umm....
  #   OVERRIDE_DIR_PERMISSION = 750
  #   OVERRIDE_FILE_PERMISSION = 0620
  #   CONFIG_WITH_SYSTEM = %[
  #     path #{TMP_DIR_WITH_SYSTEM}/out_file_test
  #     compress gz
  #     utc
  #     <system>
  #       file_permission #{OVERRIDE_FILE_PERMISSION}
  #       dir_permission #{OVERRIDE_DIR_PERMISSION}
  #     </system>
  #   ]

  #   setup do
  #     omit "NTFS doesn't support UNIX like permissions" if Fluent.windows?
  #     FileUtils.rm_rf(TMP_DIR_WITH_SYSTEM)
  #   end

  #   def parse_system(text)
  #     basepath = File.expand_path(File.dirname(__FILE__) + '/../../')
  #     Fluent::Config.parse(text, '(test)', basepath, true).elements.find { |e| e.name == 'system' }
  #   end

  #   test 'write to file with permission specifications' do
  #     system_conf = parse_system(CONFIG_WITH_SYSTEM)
  #     sc = Fluent::SystemConfig.new(system_conf)
  #     Fluent::Engine.init(sc)
  #     d = create_driver CONFIG_WITH_SYSTEM

  #     time = Time.parse("2011-01-02 13:14:15 UTC").to_i
  #     d.emit({"a"=>1}, time)
  #     d.emit({"a"=>2}, time)

  #     # FileOutput#write returns path
  #     paths = d.run
  #     expect_paths = ["#{TMP_DIR_WITH_SYSTEM}/out_file_test.20110102_0.log.gz"]
  #     assert_equal expect_paths, paths

  #     check_gzipped_result(paths[0], %[2011-01-02T13:14:15Z\ttest\t{"a":1}\n] + %[2011-01-02T13:14:15Z\ttest\t{"a":2}\n])
  #     dir_mode = "%o" % File::stat(TMP_DIR_WITH_SYSTEM).mode
  #     assert_equal(OVERRIDE_DIR_PERMISSION, dir_mode[-3, 3].to_i)
  #     file_mode = "%o" % File::stat(paths[0]).mode
  #     assert_equal(OVERRIDE_FILE_PERMISSION, file_mode[-3, 3].to_i)
  #   end
  # end

  # sub_test_case 'format specified' do
  #   test 'json' do
  #     d = create_driver [CONFIG, 'format json', 'include_time_key true', 'time_as_epoch'].join("\n")

  #     time = Time.parse("2011-01-02 13:14:15 UTC").to_i
  #     d.emit({"a"=>1}, time)
  #     d.emit({"a"=>2}, time)

  #     # FileOutput#write returns path
  #     paths = d.run
  #     check_gzipped_result(paths[0], %[#{Yajl.dump({"a" => 1, 'time' => time})}\n] + %[#{Yajl.dump({"a" => 2, 'time' => time})}\n])
  #   end

  #   test 'ltsv' do
  #     d = create_driver [CONFIG, 'format ltsv', 'include_time_key true'].join("\n")

  #     time = Time.parse("2011-01-02 13:14:15 UTC").to_i
  #     d.emit({"a"=>1}, time)
  #     d.emit({"a"=>2}, time)

  #     # FileOutput#write returns path
  #     paths = d.run
  #     check_gzipped_result(paths[0], %[a:1\ttime:2011-01-02T13:14:15Z\n] + %[a:2\ttime:2011-01-02T13:14:15Z\n])
  #   end

  #   test 'single_value' do
  #     d = create_driver [CONFIG, 'format single_value', 'message_key a'].join("\n")

  #     time = Time.parse("2011-01-02 13:14:15 UTC").to_i
  #     d.emit({"a"=>1}, time)
  #     d.emit({"a"=>2}, time)

  #     # FileOutput#write returns path
  #     paths = d.run
  #     check_gzipped_result(paths[0], %[1\n] + %[2\n])
  #   end
  # end

  # test 'path with index number' do
  #   time = Time.parse("2011-01-02 13:14:15 UTC").to_i
  #   formatted_lines = %[2011-01-02T13:14:15Z\ttest\t{"a":1}\n] + %[2011-01-02T13:14:15Z\ttest\t{"a":2}\n]

  #   write_once = ->(){
  #     d = create_driver
  #     d.emit({"a"=>1}, time)
  #     d.emit({"a"=>2}, time)
  #     d.run
  #   }

  #   assert !File.exist?("#{TMP_DIR}/out_file_test.20110102_0.log.gz")

  #   # FileOutput#write returns path
  #   paths = write_once.call
  #   assert_equal ["#{TMP_DIR}/out_file_test.20110102_0.log.gz"], paths
  #   check_gzipped_result(paths[0], formatted_lines)
  #   assert_equal 1, Dir.glob("#{TMP_DIR}/out_file_test.*").size

  #   paths = write_once.call
  #   assert_equal ["#{TMP_DIR}/out_file_test.20110102_1.log.gz"], paths
  #   check_gzipped_result(paths[0], formatted_lines)
  #   assert_equal 2, Dir.glob("#{TMP_DIR}/out_file_test.*").size

  #   paths = write_once.call
  #   assert_equal ["#{TMP_DIR}/out_file_test.20110102_2.log.gz"], paths
  #   check_gzipped_result(paths[0], formatted_lines)
  #   assert_equal 3, Dir.glob("#{TMP_DIR}/out_file_test.*").size
  # end

  # test 'append' do
  #   time = Time.parse("2011-01-02 13:14:15 UTC").to_i
  #   formatted_lines = %[2011-01-02T13:14:15Z\ttest\t{"a":1}\n] + %[2011-01-02T13:14:15Z\ttest\t{"a":2}\n]

  #   write_once = ->(){
  #     d = create_driver %[
  #       path #{TMP_DIR}/out_file_test
  #       compress gz
  #       utc
  #       append true
  #     ]
  #     d.emit({"a"=>1}, time)
  #     d.emit({"a"=>2}, time)
  #     d.run
  #   }

  #   # FileOutput#write returns path
  #   paths = write_once.call
  #   assert_equal ["#{TMP_DIR}/out_file_test.20110102.log.gz"], paths
  #   check_gzipped_result(paths[0], formatted_lines)
  #   paths = write_once.call
  #   assert_equal ["#{TMP_DIR}/out_file_test.20110102.log.gz"], paths
  #   check_gzipped_result(paths[0], formatted_lines * 2)
  #   paths = write_once.call
  #   assert_equal ["#{TMP_DIR}/out_file_test.20110102.log.gz"], paths
  #   check_gzipped_result(paths[0], formatted_lines * 3)
  # end

  # test 'symlink' do
  #   omit "Windows doesn't support symlink" if Fluent.windows?
  #   conf = CONFIG + %[
  #     symlink_path #{SYMLINK_PATH}
  #   ]
  #   symlink_path = "#{SYMLINK_PATH}"

  #   d = Fluent::Test::TestDriver.new(Fluent::FileOutput).configure(conf)

  #   begin
  #     d.instance.start
  #     10.times { sleep 0.05 }

  #     time = Time.parse("2011-01-02 13:14:15 UTC").to_i
  #     es = Fluent::OneEventStream.new(time, {"a"=>1})
  #     d.instance.emit_events('tag', es)

  #     assert File.exist?(symlink_path)
  #     assert File.symlink?(symlink_path)

  #     es = Fluent::OneEventStream.new(event_time("2011-01-03 14:15:16 UTC"), {"a"=>2})
  #     d.instance.emit_events('tag', es)

  #     assert File.exist?(symlink_path)
  #     assert File.symlink?(symlink_path)

  #     meta = d.instance.metadata('tag', event_time("2011-01-03 14:15:16 UTC"), {})
  #     assert_equal d.instance.buffer.instance_eval{ @stage[meta].path }, File.readlink(symlink_path)
  #   ensure
  #     d.instance.shutdown
  #     FileUtils.rm_rf(symlink_path)
  #   end
  # end

  # sub_test_case 'path' do
  #   test 'normal' do
  #     d = create_driver(%[
  #       path #{TMP_DIR}/out_file_test
  #       time_slice_format %Y-%m-%d-%H
  #       utc true
  #     ])
  #     time = Time.parse("2011-01-02 13:14:15 UTC").to_i
  #     d.emit({"a"=>1}, time)
  #     # FileOutput#write returns path
  #     paths = d.run
  #     assert_equal ["#{TMP_DIR}/out_file_test.2011-01-02-13_0.log"], paths
  #   end

  #   test 'normal with append' do
  #     d = create_driver(%[
  #       path #{TMP_DIR}/out_file_test
  #       time_slice_format %Y-%m-%d-%H
  #       utc true
  #       append true
  #     ])
  #     time = Time.parse("2011-01-02 13:14:15 UTC").to_i
  #     d.emit({"a"=>1}, time)
  #     paths = d.run
  #     assert_equal ["#{TMP_DIR}/out_file_test.2011-01-02-13.log"], paths
  #   end

  #   test '*' do
  #     d = create_driver(%[
  #       path #{TMP_DIR}/out_file_test.*.txt
  #       time_slice_format %Y-%m-%d-%H
  #       utc true
  #     ])
  #     time = Time.parse("2011-01-02 13:14:15 UTC").to_i
  #     d.emit({"a"=>1}, time)
  #     paths = d.run
  #     assert_equal ["#{TMP_DIR}/out_file_test.2011-01-02-13_0.txt"], paths
  #   end

  #   test '* with append' do
  #     d = create_driver(%[
  #       path #{TMP_DIR}/out_file_test.*.txt
  #       time_slice_format %Y-%m-%d-%H
  #       utc true
  #       append true
  #     ])
  #     time = Time.parse("2011-01-02 13:14:15 UTC").to_i
  #     d.emit({"a"=>1}, time)
  #     paths = d.run
  #     assert_equal ["#{TMP_DIR}/out_file_test.2011-01-02-13.txt"], paths
  #   end
  # end
end


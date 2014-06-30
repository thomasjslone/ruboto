require 'net/telnet'
require 'ruboto/sdk_versions'

module Ruboto
  module Util
    module Emulator
      ON_WINDOWS = (RbConfig::CONFIG['host_os'] =~ /mswin|mingw/i)
      ON_MAC_OS_X = RbConfig::CONFIG['host_os'] =~ /^darwin(.*)/

      def sdk_level_name(sdk_level)
        Ruboto::SdkVersions::API_LEVEL_TO_VERSION[sdk_level] || "api_#{sdk_level}"
      end

      def start_emulator(sdk_level, no_snapshot)
        sdk_level = sdk_level.gsub(/^android-/, '').to_i
        STDOUT.sync = true
        if RbConfig::CONFIG['host_cpu'] == 'x86_64'
          if ON_MAC_OS_X
            emulator_cmd = '-m "emulator64-(arm|x86)"'
          else
            emulator_cmd = 'emulator64-arm'
          end
        else
          emulator_cmd = 'emulator-arm'
        end

        avd_name = "Android_#{sdk_level_name(sdk_level)}"
        new_snapshot = false

        if `adb devices` =~ /emulator-5554/
          t = Net::Telnet.new('Host' => 'localhost', 'Port' => 5554, 'Prompt' => /^OK\n/)
          t.waitfor(/^OK\n/)
          output = ''
          t.cmd('avd name') { |c| output << c }
          t.close
          if output =~ /(.*)\nOK\n/
            running_avd_name = $1
            if running_avd_name == avd_name
              puts "Emulator #{avd_name} is already running."
              return
            else
              puts "Emulator #{running_avd_name} is running."
            end
          else
            raise "Unexpected response from emulator: #{output.inspect}"
          end
        else
          puts 'No emulator is running.'
        end

        # FIXME(uwe):  Change use of "killall" to use the Ruby Process API
        loop do
          emulator_opts = '-partition-size 256'
          emulator_opts << ' -no-snapshot-load' if no_snapshot
          if !ON_MAC_OS_X && !ON_WINDOWS && ENV['DISPLAY'].nil?
            emulator_opts << ' -no-window -no-audio'
          end

          `killall -0 #{emulator_cmd} 2> /dev/null`
          if $? == 0
            `killall #{emulator_cmd}`
            10.times do |i|
              `killall -0 #{emulator_cmd} 2> /dev/null`
              if $? != 0
                break
              end
              if i == 3
                print 'Waiting for emulator to die: ...'
              elsif i > 3
                print '.'
              end
              sleep 1
            end
            puts
            `killall -0 #{emulator_cmd} 2> /dev/null`
            if $? == 0
              puts 'Emulator still running.'
              `killall -9 #{emulator_cmd}`
              sleep 1
            end
          end

          avd_home = "#{ENV['HOME'].gsub('\\', '/')}/.android/avd/#{avd_name}.avd"

          unless File.exists? avd_home
            puts "Creating AVD #{avd_name}"

            target = `android list target`.split(/----------\n/).
                find { |l| l =~ /android-#{sdk_level}/ }

            if target.nil?
              puts "Target android-#{sdk_level} not found.  You should run"
              puts "\n    ruboto setup -y -t #{sdk_level}\n\nto install it."
              exit 3
            end

            if ON_MAC_OS_X || ON_WINDOWS
              abis = target.slice(/(?<=ABIs : ).*/).split(', ')
              has_haxm = abis.find { |a| a =~ /x86/ }
            end

            # FIXME(uwe): The x86 emulator does not respect the heap setting and
            # restricts to a 16MB heap on Android 2.3 which will crash any
            # Ruboto app.  Remove the first "if" below when heap setting works
            # on x86 emulator.
            # https://code.google.com/p/android/issues/detail?id=37597
            # https://code.google.com/p/android/issues/detail?id=61596
            if sdk_level == 10
              abi_opt = '--abi armeabi'
            else
              if has_haxm
                abi_opt = '--abi x86'
              else
                if [17, 16, 15, 13, 11].include? sdk_level
                  abi_opt = '--abi armeabi-v7a'
                elsif sdk_level == 10
                  abi_opt = '--abi armeabi'
                end
              end
            end
            # EMXIF

            puts `echo n | android create avd -a -n #{avd_name} -t android-#{sdk_level} #{abi_opt} -c 64M -s HVGA`

            if $? != 0
              puts 'Failed to create AVD.'
              exit 3
            end
            avd_config_file_name = "#{avd_home}/config.ini"
            old_avd_config = File.read(avd_config_file_name)
            manifest_file = 'AndroidManifest.xml'
            heap_size = (File.exists?(manifest_file) && File.read(manifest_file) =~ /largeHeap/) ? 256 : 48
            new_avd_config = old_avd_config.gsub(/vm.heapSize=([0-9]*)/) { |m| $1.to_i < heap_size ? "vm.heapSize=#{heap_size}" : m }
            add_property(new_avd_config, 'hw.device.manufacturer', 'Generic')
            add_property(new_avd_config, 'hw.device.name', '3.2" HVGA slider (ADP1)')
            add_property(new_avd_config, 'hw.mainKeys', 'yes')
            add_property(new_avd_config, 'hw.sdCard', 'yes')

            File.write(avd_config_file_name, new_avd_config) if new_avd_config != old_avd_config
            new_snapshot = true
          end

          puts "Start emulator#{' without snapshot' if no_snapshot}"
          system "emulator -avd #{avd_name} #{emulator_opts} #{'&' unless ON_WINDOWS}"
          return if ON_WINDOWS

          3.times do |i|
            sleep 1
            `killall -0 #{emulator_cmd} 2> /dev/null`
            if $? == 0
              break
            end
            if i == 3
              print 'Waiting for emulator: ...'
            elsif i > 3
              print '.'
            end
          end
          puts
          `killall -0 #{emulator_cmd} 2> /dev/null`
          if $? != 0
            puts 'Unable to start the emulator.  Retrying without loading snapshot.'
            system "emulator -no-snapshot-load -avd #{avd_name} #{emulator_opts} #{'&' unless ON_WINDOWS}"
            10.times do |i|
              `killall -0 #{emulator_cmd} 2> /dev/null`
              if $? == 0
                new_snapshot = true
                break
              end
              if i == 3
                print 'Waiting for emulator: ...'
              elsif i > 3
                print '.'
              end
              sleep 1
            end
          end

          `killall -0 #{emulator_cmd} 2> /dev/null`
          if $? == 0
            print 'Emulator started: '
            50.times do
              break if device_ready?
              print '.'
              sleep 1
            end
            puts
            break if device_ready?
            puts 'Emulator started, but failed to respond.'
            unless no_snapshot
              puts 'Retrying without loading snapshot.'
              no_snapshot = true
            end
          else
            puts 'Unable to start the emulator.'
          end
        end

        if new_snapshot
          puts 'Allow the emulator to calm down a bit.'
          sleep 15
        end

        system <<EOF
(
  set +e
  for i in 1 2 3 4 5 6 7 8 9 10 ; do
    sleep 6
    adb shell input keyevent 82 >/dev/null 2>&1
    if [ "$?" = "0" ] ; then
      set -e
      adb shell input keyevent 82 >/dev/null 2>&1
      adb shell input keyevent 4 >/dev/null 2>&1
      exit 0
    fi
  done
  echo "Failed to unlock screen"
  set -e
  exit 1
) &
EOF
        system 'adb logcat > adb_logcat.log &'

        puts "Emulator #{avd_name} started OK."
      end

      def device_ready?
        `adb get-state`.gsub(/^WARNING:.*$/, '').chomp == 'device'
      end

      def add_property(new_avd_config, property_name, value)
        pattern = /^#{property_name}=.*$/
        property = "#{property_name}=#{value}"
        if new_avd_config =~ pattern
          new_avd_config.gsub! pattern, property
          puts "Changed property: #{property}"
        else
          new_avd_config << "#{property}\n"
          puts "Added property: #{property}"
        end
      end
    end
  end
end

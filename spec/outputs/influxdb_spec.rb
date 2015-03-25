# Disclaimer: I don't really know what I'm doing.
#
# You can run these tests like this:
#   jruby -S rspec spec/outputs/influxdb_spec.rb

require "logstash/devutils/rspec/spec_helper"
require "logstash/outputs/influxdb"
require "logstash/event"

# Fake plugin that overrides post(body), and bypasses some unnecessary setup.
class FakePlugin < LogStash::Outputs::InfluxDB
  # Get the body of the last post
  def body
    @body
  end

  # Get how many post attempts have we made
  def attempt_count
    @attempt_count.nil? ? 0 : @attempt_count
  end

  # Set how many times post(body) should fail with exception
  def set_number_of_post_fails(fail_count)
    @remaining_fail_count = fail_count
  end

  # Simplified version of the plugin's register(), which avoids importing FTW::Agent::Configuration
  def register
    @queue = []
    @logger = Logger.new(STDOUT)
    @logger.level = Logger::DEBUG

    # Buffer is sufficiently big and with a big enough delay that it won't flush on its own
    buffer_initialize(
      :max_items => 100,
      :max_interval => 100,
      :logger => nil
    )
  end

  # Overridden plugin function - we capture the last body posted for later inspection, and fail @remaining_fail_count
  # times with exception.
  def post(body)
    @attempt_count = attempt_count() + 1
    if !@remaining_fail_count.nil? and @remaining_fail_count > 0
        @remaining_fail_count -= 1
        raise "Planned fail to post(body)"
    end
    @body = body
  end
end

describe LogStash::Outputs::InfluxDB do
  event1 = {
    "message"=> "Mar 25 00:45:12 info host1 Program1: Hello world!",
    "@version"=> "1",
    "@timestamp"=> "2015-03-25T04:45:12.000Z",
    "host"=> "localhost",
    "@message"=> "Hello world!",
    "influxdb_data_points"=>
    { "user"=> "fprefect",
      "i_account"=> "1000",
      "i_foo"=> "1",
      "f_timing"=> "1.23",
      "host"=> "host1"
    }
  }

  event2 = {
    "message"=> "Mar 26 00:45:12 info host2 Prog1: Hi!",
    "@version"=> "1",
    "@timestamp"=> "2015-03-26T04:45:12.000Z",
    "host"=> "localhost",
    "@message"=> "Hi!",
    "influxdb_data_points"=>
    { "user"=> "adent",
      "i_account"=> "1001",
      "i_foo"=> "2",
      "f_timing"=> "1.43",
      "host"=> "host2"
    }
  }

  event3 = {
    "message"=> "Mar 27 00:45:12 info host2 Prog1: Hey Now!",
    "@version"=> "1",
    "@timestamp"=> "2015-03-27T04:45:12.000Z",
    "host"=> "localhost",
    "@message"=> "Hey Now!",
    "influxdb_data_points"=>
    { "user"=> "zbeeblebrox",
      "i_account"=> "1002",
      "i_foo"=> "3",
      "f_timing"=> "1.53",
      "host"=> "host3"
    }
  }

  describe 'data_points and event_data_points play nice' do
    # Make sure that fields from data_points and in a 'event_data_points_key' hash are merged

    plugin = FakePlugin.new({
      'host' => 'localhost',
      'user' => 'foo',
      'password' => 'hey',
      'data_points' => {
        'message' => '%{@message}'
      },
      'series' => 'my_series',
      'event_data_points_key' => 'influxdb_data_points',
      'data_points_type_prefixes' => {
        'integer' => ['i_'],
        'float' => ['f_'],
        'boolean' => ['b_']}
    })
    plugin.register()

    plugin.receive(LogStash::Event.new(event1))
    plugin.receive(LogStash::Event.new(event2))
    plugin.receive(LogStash::Event.new(event3))

    flush_count = plugin.buffer_flush(:force => true)
    insist { flush_count } == 3

    # We should see both the data_points field and those defined in our hash
    expected_body = <<END
[{"name":"my_series","columns":["message","user","i_account","i_foo","f_timing","host","time"],"points":[["Hello world!","fprefect",1000,1,1.23,"host1",1427258712],["Hi!","adent",1001,2,1.43,"host2",1427345112],["Hey Now!","zbeeblebrox",1002,3,1.53,"host3",1427431512]]}]
END
    expected_body = expected_body.chop
    insist {plugin.body} == expected_body
    insist {plugin.attempt_count} == 1
  end

  describe 'Retry sends proper batch' do
    # Simulate InfluxDB being down, and make sure when it comes back up, the batch looks proper - no dupes
    plugin = FakePlugin.new({
      'host' => 'localhost',
      'user' => 'foo',
      'password' => 'hey',
      'data_points' => {
        'message' => '%{@message}'
      },
      'series' => 'my_series',
      'event_data_points_key' => 'influxdb_data_points',
      'data_points_type_prefixes' => {
        'integer' => ['i_'],
        'float' => ['f_'],
        'boolean' => ['b_']}
    })
    plugin.set_number_of_post_fails(3)
    plugin.register()

    plugin.receive(LogStash::Event.new(event1))
    plugin.receive(LogStash::Event.new(event2))
    plugin.receive(LogStash::Event.new(event3))

    flush_count = plugin.buffer_flush(:force => true)
    insist { flush_count } == 3

    # We should see both the data_points field and those defined in our hash
    expected_body = <<END
[{"name":"my_series","columns":["message","user","i_account","i_foo","f_timing","host","time"],"points":[["Hello world!","fprefect",1000,1,1.23,"host1",1427258712],["Hi!","adent",1001,2,1.43,"host2",1427345112],["Hey Now!","zbeeblebrox",1002,3,1.53,"host3",1427431512]]}]
END
    expected_body = expected_body.chop
    insist {plugin.body} == expected_body
    insist {plugin.attempt_count} == 4
  end

  describe 'data_points does not hold previous event values' do
    plugin = FakePlugin.new({
      'host' => 'localhost',
      'user' => 'foo',
      'password' => 'hey',
      'data_points' => {
        'message' => '%{@message}'
      },
      'series' => 'my_series',
      'event_data_points_key' => 'influxdb_data_points',
      'data_points_type_prefixes' => {
        'integer' => ['i_'],
        'float' => ['f_'],
        'boolean' => ['b_']}
    })
    plugin.register()

    # Create a new event with all the same fields except 'f_timing', and make sure f_timing isn't holding the previous value
    event4 = {
      "message"=> "Mar 27 00:45:12 info host2 Prog1: Hey Now!",
      "@version"=> "1",
      "@timestamp"=> "2015-03-27T04:45:12.000Z",
      "host"=> "localhost",
      "@message"=> "Good morning.",
      "influxdb_data_points"=>
      { "user"=> "lprocesser",
        "i_account"=> "1003",
        "i_foo"=> "4",
        "host"=> "host4"
      }
    }

    plugin.receive(LogStash::Event.new(event1))
    plugin.receive(LogStash::Event.new(event2))
    plugin.receive(LogStash::Event.new(event3))
    plugin.receive(LogStash::Event.new(event4))

    flush_count = plugin.buffer_flush(:force => true)
    insist { flush_count } == 4

    # We should see both the data_points field and those defined in our hash
    expected_body = <<END
[{"name":"my_series","columns":["message","user","i_account","i_foo","f_timing","host","time"],"points":[["Hello world!","fprefect",1000,1,1.23,"host1",1427258712],["Hi!","adent",1001,2,1.43,"host2",1427345112],["Hey Now!","zbeeblebrox",1002,3,1.53,"host3",1427431512]]},{"name":"my_series","columns":["message","user","i_account","i_foo","host","time"],"points":[["Good morning.","lprocesser",1003,4,"host4",1427431512]]}]
END
    expected_body = expected_body.chop
    insist {plugin.body} == expected_body
  end
end
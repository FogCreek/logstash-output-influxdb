Why Fork?
=========

The original Logstash output plugin for InfluxDB allows you to configure
key/value pairs from log event variables, but only if you know them ahead
of time. For example, if you wanted to add a new key/value into InfluxDB,
you'd need to update your LogStash filters to parse out the field, and
this plugin configuration to send them to InfluxDB.

Add/Remove Key/Value Pairs Without Updating LogStash Config
-----------------------------------------------------------

This updated plugin lets you dynamically create a hash of key/values in your
LogStash filters, and pass all of that hash's key/values to the plugin. You 
can standardize a log format that contains data to be delivered to InfluxDB 
without having to update your LogStash config.

What about types?
-----------------

### Determined by Key Prefixes

I'm glad you asked! Since we're able to pull key/value pairs out of the log
message on the fly, coerce_values isn't going to be much help to us anymore.
Instead, you can standardize your types by key prefix. For example, you can
configure values as being integers if their keys start with "i_" or "int_",
floats if they start with "f_", and booleans if they start with "b_" or
"bool_". 

### Overriding with coerce_values

Entries in coerce_values will always take precedence, so you can configure
the key prefix "f_" as representing a float, but still have "f_somevalue" 
represent as a string by including "f_somevalue" in coerce_values.

Example
-------

This example expects the log format:

    <some date> <level> <host> <programname>: <log message> ==> <key>=<value>; <key>=<value>; <key>="value";

Here's a log statement:

    Mar 18 16:05:45 info backend1 AuthService: Log msg: Login successful! ==> i_userid=42; username="fordp"; f_timing_ms=3.1415;

And here's the LogStash configuration that reads from auth_service.log, parses
key/value pairs after "==>", casts the values to integer, float, and booleans
by their prefix, and sends them to InfluxDB.

	input {
		file {
			path => "/var/log/remote/auth_service.log"
			codec => "plain"
			sincedb_path => "/var/tmp/.auth_service"
			sincedb_write_interval => 15
			type => "syslog"
			tags => [ "influxdb_source" ]
			add_field => {
				"influxdb_series"    => "auth_service"
			}
		}
	}

	# Dynamically parse key/value pairs from the log message
	filter {
		if "influxdb_source" in [tags] {
			# This is a source that is configured to send messages to InfluxDB. 
			# Look for key-value pairings after "==>" in the log message.
			grok {
				# Parse key/values after ==>
				match => [ "message", ".+ ==> %{GREEDYDATA:key_value_candidates}" ]
			}
			kv {
				# Look for key-value pairings
				source => "key_value_candidates"
				trim => ";"
				target => "influxdb_data_points"
				add_field => {
					"send_to_influx_db" => true
				}
			}
			mutate {
				remove_field => "key_value_candidates"
			}
		}
	}

	# Send the key/value pairs stored in "influxdb_data_points" hash, 
	# typecasting integers, floats, and booleans by prefixes.
	output {
		if [send_to_influx_db] {
			influxdb {
				host => "localhost"
				data_points => {
					# This is hard-coded in every InfluxDB record 
					"foo" => 1337
					# You can also add other values that are in every log statement
					"message" => "%{message}"
				}
				# Here's the event key that contains a hash of our data points
				event_data_points_key => "influxdb_data_points"
				data_points_type_prefixes => {
					"integer" => ["i_", "int_"]
					"float" => ["f_", "float_"]
					"boolean" => ["b_", "bool_", "boolean_"]
				}
				coerce_values => {
					 # Force this to string to bypass prefix typing
					 "i_something" => "string"
				}
				user => "root"
				password => "root"
				port => 8086
				series => "%{influxdb_series}"
				db => "stats"
			}
		}
	}

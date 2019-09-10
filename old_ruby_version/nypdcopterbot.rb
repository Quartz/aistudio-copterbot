require 'twitter'
require 'mysql2'
require 'date'
require 'time'
require 'yaml'
require 'net/http'
require 'restclient'
require 'aws-sdk-s3'
require_relative "./utils"
require 'fileutils'


prod_mapping_interval = 10  # min, should be 15
dev_mapping_interval = 15
mapping_interval = ENV["NEVERTWEET"] || ENV["NEVERTOOT"] ? (ENV['MAPINTVL'] || dev_mapping_interval) : prod_mapping_interval
delay = 0 # min, default 5 min

MIN_POINTS = 3 # number of points to require before tweeting a map. probably actually ought to be more!

# select hex(icao_addr), count(*) from squitters where hex(icao_addr) in ('AAADB2','ACB1F5', 'ACB5AC', 'ACB963', 'ACBF73', 'A36989', 'A50456', 'A4E445', 'A206AC' ) group by hex(icao_addr);

BUCKET = 'qz-aistudio-jbfm-scratch'

MYSQLCLIENT = Mysql2::Client.new(
  :host => ENV['MYSQLHOST'],
  :port => ENV['MYSQLPORT'],
  :username => ENV['MYSQLUSER'] || ENV['MYSQLUSERNAME'],
  :password => ENV['MYSQLPASSWORD'],
  :database => ENV['MYSQLDATABASE'] || "dump1090"
)
creds = YAML.load_file(File.join(File.dirname(__FILE__), "creds.yml"))
unless ENV['NEVERTWEET']
	twitterclient = Twitter::REST::Client.new do |config|
  		config.consumer_key        = creds["twitter"]["consumer_key"]
  		config.consumer_secret     = creds["twitter"]["consumer_secret"]
  		config.access_token        = creds["twitter"]["token"]
  		config.access_token_secret = creds["twitter"]["secret"]
	end
end

PNG_PATH = "/tmp/hover/"
FileUtils.mkdir_p(PNG_PATH)

messages = [
  "NYPD helicopter ~NNUM~ is in the air over New York City. I last saw it at ~TIME2~.",
  "Chop chop chop, there goes NYPD copter ~NNUM~ flyin' over. I last saw it at ~TIME2~.",
  "I wonder what's going on? NYPD chopper ~NNUM~ is up in the air. I last saw it at ~TIME2~."
  #........................................................................................................................................
]
non_pd_msg = "Interesting plane ~NNUM~ is flying. I last saw it at ~TIME2~."

messages_with_neighborhoods = [
  "NYPD helicopter ~NNUM~ is in the air over ~NEIGHBORHOODS~. I last saw it at ~TIME2~.",
  "Chop chop chop, there goes NYPD helicopter ~NNUM~ flyin' over ~NEIGHBORHOODS~. Last seen at ~TIME2~.",
  "I wonder what's going on? NYPD helicopter ~NNUM~ is up in the air at ~TIME2~ above ~NEIGHBORHOODS~."
]

new_sayings = [
  "Sorry you got woken up… NYPD helicopter ~NNUM~ has been hovering over ~HOVERNEIGHBORHOODS~ from about ~TIME1~ to ~TIME2~. Do you have any idea why? Reply and let us know.",
  "You aren’t imagining it, that helicopter has been there a while. We’ve detected that NYPD helicopter ~NNUM~ has been hovering over ~HOVERNEIGHBORHOODS~ for ~DURATION~. We want to find out why. Do you know? Tell us!",
  "Welp, ~HOVERNEIGHBORHOODS~, that helicopter has been hovering there for a while, no? Got a clue what’s happening nearby that NYPD is responding to? Tell us!",
  "CHOP CHOP chop chop … [silence] … chop chop chop … [silence] … chop CHOP CHOP.\n\n That police helicopter’s been hovering over ~HOVERNEIGHBORHOODS~ since ~TIME1~… Wonder what it’s up to? Stay tuned. If you know, say so below (plz!).",
  "CHOP CHOP chop chop … [silence] … chop chop chop … [silence] … chop CHOP CHOP.\n\n That police helicopter’s been hovering overhead since ~TIME1~… Wonder what it’s up to? Stay tuned. If you know, say so below (plz!).",
  "There’s an NYPD helicopter hovering over ~BRIDGENAME~. Probably traffic, but maybe not. Do you know what’s happening?",
]

# still hovering or not?
# neighborhoods or not?
# bridge or not?


def andify(list)
  return list.first || '' if list.size <= 1 
  "#{list[0...-1].join(", ")} and #{list[-1]}"
end

def generate_shingled_maps_for_trajectory(helicopter_icao_hex, helicopter_nnum, trajectory_start_time, trajectory_end_time)
  results = MYSQLCLIENT.query(%{
    SELECT *, 
      convert_tz(parsed_time, '+00:00', 'US/Eastern') datetz, 
      conv(icao_addr, 10,16) as icao_hex
    FROM squitters 
    WHERE icao_addr = conv('#{helicopter_icao_hex}', 16,10) and 
      lat is not null
      AND parsed_time >= '#{trajectory_start_time}'
      AND parsed_time <= '#{trajectory_end_time}'
    order by parsed_time desc;}.gsub(/\s+/, " ").strip)

    puts "Shingle has #{results.count} points"
    begin
      shingled_trajectory = generate_shingles_for_trajectory(results.to_a)
    rescue HelicopterShinglingError
      return []
    end

    # trajectories need a stable ID, as do shingles.
    # does NNum, icao hex and start, end times do it? I suppose, right?
    shingled_trajectory.map do |shingle|
        next if shingle.length == 0
        shingle_start_time = shingle[-1]["parsed_time"].to_s.gsub(/ -0\d00/, '')
        shingle_end_time = shingle[0]["parsed_time"].to_s.gsub(/ -0\d00/, '')
        shingle_png_fn, shingle_svg_fn, shingle_metadata_fn = generate_shingle_map_from_shingle(shingle[0]["icao_hex"], helicopter_nnum, shingle_start_time, shingle_end_time,  PNG_PATH)        
        [shingle_start_time, shingle_end_time, shingle_png_fn, shingle_metadata_fn]
    end
end

def figure_out_if_hovering(helicopter_id, helicopter_nnum, trajectory_start_time, trajectory_end_time)
  map_image_fns = generate_shingled_maps_for_trajectory(helicopter_id, helicopter_nnum, trajectory_start_time, trajectory_end_time)
  map_image_fns.map do |shingle_start_time, shingle_end_time, map_image_fn, shingle_metadata_fn|
    shingle_metadata = JSON.parse(open(shingle_metadata_fn, 'r'){|f| f.read })
    was_it_hovering = `python3 #{File.dirname(__FILE__)}/classify_one_map.py "#{map_image_fn}"` # python classify_one_map.py N920PD-2019-04-17-0900-2019-04-17-0930.png
    was_it_hovering.strip!
    puts was_it_hovering
    was_it_hovering = was_it_hovering == 'hover'
    # do something with was_it_hovering.
    [shingle_start_time, shingle_end_time, was_it_hovering, shingle_metadata["centerpoint"]]
  end
end

aircraft.each do |nnum, icao|
  begin
    # parsed_time is the current time on the rpi, so regardless of the garbage given by the airplane, that should work
    # however, it causes some NYPD helicopters to be tweeted too much
    # but without it, n725dt is never tweeted
    # TODO: should I modify dump1090-stream-parser so that one of the timing columns is current time on the DB? (e.g. with MYSQL @@current_time or whatever)
    results = MYSQLCLIENT.query(%{
      SELECT *, convert_tz(parsed_time, '+00:00', 'US/Eastern') datetz 
      FROM squitters 
      WHERE icao_addr = conv('#{icao}', 16,10) and 
        lat is not null and 
        convert_tz(parsed_time, '+00:00', 'US/Eastern') > DATE_SUB(convert_tz(NOW(), '+00:00', 'US/Eastern'), interval #{mapping_interval} minute) and 
        convert_tz(parsed_time, '+00:00', 'US/Eastern') < convert_tz(NOW(), '+00:00', 'US/Eastern') 
      order by parsed_time desc;}.gsub(/\s+/, " ").strip)
    puts "#{Time.now} results: #{results.count} (#{nnum} / #{icao})"
    next unless results.count >= 2

    # generate the SVG to tweet
    svg_fn = `MAXTIMEDIFF=#{10} /usr/local/bin/node #{File.dirname(__FILE__)}/../dump1090-mapper/mapify.js --n-number #{nnum}  #{icao}`
    svg_fn.strip!
    puts "svg: #{svg_fn.inspect}"    


    metadata_fn = svg_fn.gsub(".svg", ".metadata.json")
    metadata = JSON.parse(open(metadata_fn, 'r'){|f| f.read })
    neighborhood_names = metadata["nabes"].map{|name| name.gsub("Brg", "Bridge") }
    hover_neighborhood_names = metadata["hover_nabes"].map{|name| name.gsub("Brg", "Bridge") }

    # not currently used, just trying not to forget about 'em.
    start_recd_time = metadata["start_recd_time"]
    end_recd_time = metadata["end_recd_time"]
    points_cnt = metadata["points_cnt"]

    next if points_cnt < MIN_POINTS

    png_datetime = Time.now.strftime("%Y-%m-%d_%H_%M_%S")
    png_fn = svg_fn[0...-4] + png_datetime +  ".png"
    new_metadata_fn = metadata_fn.gsub(".metadata.json", "-" + png_datetime + ".metadata.json")
    File.rename(metadata_fn, new_metadata_fn)

    png_start_time = Time.now
    screenshot_svg_to_png(svg_fn, png_fn)
    png_duration_secs = Time.now - png_start_time
    puts "png: #{png_fn}, generation took #{png_duration_secs}s"


    # is it hovering?
    when_hovering = false
    start_time_for_trajectory = (DateTime.parse(end_recd_time) - (1.0/24/4)).to_s.split("+")[0].gsub("T", " ")
    # only look back 15 minutes (for longer trajectories it's a waste of time to re-calculate whether it was hovering 45 minutes ago -- since we've already figured it out)
    puts("start_recd_time", start_recd_time)
    puts("start_time_for_trajectory", start_time_for_trajectory)
    res = figure_out_if_hovering(icao, nnum, start_recd_time, end_recd_time)
    puts "when is it hovering? " + res.inspect
    hovering_shingles = res.select{|shingle_start, shingle_end, was_hovering, centerpoint| was_hovering}.map{|shingle_start, shingle_end, was_hovering, centerpoint| [shingle_start, shingle_end]}
    currently_hovering = res[-2..-1] && res[-1 * [2, res.size].max..-1].any?{|shingle_start, shingle_end, was_hovering, centerpoint| was_hovering}

    latest_shingle_centerpoint = res.select{|shingle_start, shingle_end, was_hovering, centerpoint| was_hovering}.sort_by{|shingle_start, shingle_end, was_hovering, centerpoint| shingle_end }.map{|shingle_start, shingle_end, was_hovering, centerpoint| centerpoint }[-1]
    shingle_centerpoints = Hash[*res.select{|shingle_start, shingle_end, was_hovering, centerpoint| was_hovering}.map{|shingle_start, shingle_end, was_hovering, centerpoint| [[shingle_start, shingle_end], centerpoint] }.flatten(1)]
    when_hovering = if hovering_shingles.size > 0
                      shingle_time_count = Hash[*hovering_shingles.flatten.group_by{|a| a}.map{|k, v| [k, v.count]}.flatten]
                      shingle_times = hovering_shingles.flatten.reject{|x| shingle_time_count[x] == 2} # exclude times that occur twice
                      puts shingle_times.inspect
                      andify(shingle_times.each_slice(2).map{|a, b| "#{a.split(" ")[1]} to #{b.split(" ")[1]} at #{shingle_centerpoints[[a,b]]}"})
                    else 
                      false
                    end
    puts "IT HOVERED: #{when_hovering}" if when_hovering

    if when_hovering
      arbitrary_marker = latest_shingle_centerpoint ? "--arbitrary-marker=#{latest_shingle_centerpoint['lon']},#{latest_shingle_centerpoint['lat']}" : ''
      svg_fn = `MAXTIMEDIFF=#{10} /usr/local/bin/node #{File.dirname(__FILE__)}/../dump1090-mapper/mapify.js --n-number #{nnum} #{arbitrary_marker} #{icao}`
      svg_fn.strip!
      puts "svg: #{svg_fn.inspect}"    
      puts $?
      puts $?.exitstatus
      png_datetime = Time.now.strftime("%Y-%m-%d_%H_%M_%S")
      png_fn = svg_fn[0...-4] + png_datetime +  ".png"
      hover_metadata_fn = svg_fn.gsub(".svg", ".metadata.json")
      hover_metadata = JSON.parse(open(hover_metadata_fn, 'r'){|f| f.read })
      hover_neighborhood_names = hover_metadata["hover_nabes"].map{|name| name.gsub("Brg", "Bridge") }
      new_hover_metadata_fn = hover_metadata_fn.gsub(".metadata.json", "-" + png_datetime + ".metadata.json")
      File.rename(hover_metadata_fn, new_hover_metadata_fn)

      png_start_time = Time.now
      screenshot_svg_to_png(svg_fn, png_fn)
      png_duration_secs = Time.now - png_start_time
      puts "new png: #{png_fn}, generation took #{png_duration_secs}s"
    end

    # coming up with the text to tweet/post
    latest_time_seen = results.first["datetz"].utc.getlocal
    first_time_seen = results.to_a.last["datetz"].utc.getlocal
    flight_duration_mins = (latest_time_seen - first_time_seen) / 60

    duration_str = flight_duration_mins > 120 ? "#{flight_duration_mins / 60} hours and #{flight_duration_mins % 60} mins" : (flight_duration_mins > 60 ? "#{flight_duration_mins / 60} hour and #{flight_duration_mins % 60} mins" : "#{flight_duration_mins} mins")

    bridge_names = neighborhood_names.select{|name| name.match(/Bridge$/)}
    if ENV["ONLY_TWEET_HOVERS"]
      return if !nnum.include?("PD") # don't tweet non-police aircraft
      tweet_text = (!(hover_neighborhood_names.nil? || hover_neighborhood_names.empty?) ? new_sayings.select{|txt| txt.include?("NEIGHBORHOODS~") } : (bridge_names.empty? ? new_sayings.reject{|txt| txt.include?("~BRIDGENAME~")} : new_sayings )).sample.dup

      if !currently_hovering
        tweet_text.gsub!("has been", "was")
        tweet_text.gsub!("’s been", " was")
        tweet_text.gsub!("There’s", "There was")
      end

      while hover_neighborhood_names.size > 0
        possible_tweet_text = tweet_text.gsub("~HOVERNEIGHBORHOODS~", andify(hover_neighborhood_names) )
        if possible_tweet_text.size < 280
          tweet_text = possible_tweet_text
          break
        else
          hover_neighborhood_names.pop
        end
      end

    else # older style.
      if neighborhood_names.nil? || !nnum.include?("PD") 
        tweet_text = nnum.include?("PD") ? messages.sample.dup : non_pd_msg
        #                 11:15 PM
      else
        tweet_text = messages_with_neighborhoods.sample.dup
        while neighborhood_names.size
          possible_tweet_text = tweet_text.gsub("~NEIGHBORHOODS~", andify(neighborhood_names) )
          if possible_tweet_text.size < 280
            tweet_text = possible_tweet_text
            break
          else
            neighborhood_names.pop
          end
        end
      end
    end

    tweet_text.gsub!("~NNUM~", nnum)
    tweet_text.gsub!("~TIME1~", first_time_seen.strftime("%-I:%M %p") )
    tweet_text.gsub!("~TIME2~", latest_time_seen.strftime("%-I:%M %p") )
    tweet_text.gsub!("~DURATION~", "#{((latest_time_seen - first_time_seen) / 60).to_i} min" )
    tweet_text.gsub!("~BRIDGENAME~", andify(hover_neighborhood_names.select{|name| name.match(/Bridge$/)}))

    debug_text = "#{points_cnt} points; #{start_recd_time.gsub(".000Z", '').gsub("T", " ")} to #{end_recd_time.gsub(".000Z", '').gsub("T", " ")}" + (when_hovering ? (" HOVERED: " + when_hovering ) : '' )
    
    debug_text += " AND IT WAS HOVERING" if when_hovering


    # uploading the image to S3, for Slack.
    s3 = Aws::S3::Resource.new(region:'us-east-1', signature_version: 'v4')

    png_s3_base_key = File.basename(png_fn)
    png_s3_key = "airplanes/" + png_s3_base_key #.gsub(".png", '') + png_datetime +  ".png"
    png_obj = s3.bucket(BUCKET).object(png_s3_key)
    png_obj.upload_file(png_fn, acl: "public-read", content_type: "image/png")

    metadata_s3_base_key = File.basename(new_metadata_fn)
    metadata_s3_key = "airplanes/" + metadata_s3_base_key 
    metadata_obj = s3.bucket(BUCKET).object(metadata_s3_key)
    metadata_obj.upload_file(new_metadata_fn, acl: "public-read", content_type: "application/json")


    # actually tweeting
    puts "trying to tweet \"#{tweet_text}\" in #{delay} min"
    puts "debug text: #{debug_text}"
    if !ENV["NEVERTWEET"] || !ENV["NEVERTOOT"]
      sleep delay * 60
    end
    unless ENV["NEVERTWEET"]
      twitterclient.update_with_media(tweet_text, File.new(png_fn), lat: latest_shingle_centerpoint['lat'], long: latest_shingle_centerpoint['lon']) if (!ENV["ONLY_TWEET_HOVERS"] || when_hovering ) 
    else
      puts "but not really tweeting"
    end
    unless ENV["NEVERTOOT"]
      if (!ENV["ONLY_TWEET_HOVERS"] || when_hovering )
        media_json = RestClient.post "#{creds['botsinspace']["instance"]}/api/v1/media", {:file => File.new(png_fn)}, {:Authorization => "Bearer #{creds["botsinspace"]["access_token"]}"}
        media =  JSON.parse(media_json.body)
        status_json = RestClient.post "#{creds['botsinspace']["instance"]}/api/v1/statuses", {:status => tweet_text, :media_ids => [media["id"]], :visibility => "public"}, {:Authorization => "Bearer #{creds["botsinspace"]["access_token"]}"}
      end
      # $stderr.puts (JSON.parse(status_json.body).inspect)
    else
      puts "but not really tooting"
    end
    unless ENV['NEVERSLACK']
      slack_payload =  {
          "text" => tweet_text + " \n " + debug_text,
          "attachments": [
            {
                "fallback": "A map of #{nnum}'s flight over the NYC area.",
                "image_url": "http://#{BUCKET}.s3.amazonaws.com/#{png_s3_key}",
            }
        ]
      }
      puts "posting to slack"
      resp = RestClient.post(creds['slack']['webhook'], JSON.dump(slack_payload), headers: {"Content-Type": "application/json"}) if (!ENV["ONLY_TWEET_HOVERS"] || when_hovering )
    end
    puts "done at #{Time.now}"
    puts "\n"
    puts "\n"
    puts "\n"
    puts "\n"
    puts "\n"
  rescue StandardError => e
    puts e.inspect
    puts e.backtrace
  end
end

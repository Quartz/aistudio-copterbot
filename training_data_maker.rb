

# for all the copters

# generate shingled (i.e. overlapping) trajectories of NN minutes, let's say 5?



# give each one an ID

# and make a map of each of them

# so that I 

# can label them as hovering or not.


require 'twitter'
require 'mysql2'
require 'date'
require 'time'
require 'yaml'
require 'net/http'
require 'restclient'
require 'aws-sdk-s3'
require 'csv'
require 'fileutils'

copters = {
  "N917PD" => "ACB1F5",
  "N918PD" => "ACB5AC",
  "N919PD" => "ACB963",
  "N920PD" => "ACBF73",
  "N319PD" => "A36989",
  "N422PD" => "A50456",
  "N414PD" => "A4E445",
  "N23FH"  => "A206AC",
}
SHINGLE_DURATION = 5 # minutes
SHINGLE_MIN_POINTS = 10 # minimum points in a trajectory.
SHINGLE_DURATION_SECS = SHINGLE_DURATION * 60

FileUtils.mkdir_p("hover_train_svg")
FileUtils.mkdir_p("hover_train_png")

begin
  additional_aircraft_str = Net::HTTP.get(URI("https://gist.githubusercontent.com/jeremybmerrill/65f3538b59032b3d66cd55165eec26b8/raw/64c78bca212c828787dc9a7eb0b26697e9fb67c4/planes.txt"))
  additional_aircraft = Hash[*additional_aircraft_str.split("\n").map{|line| line.split(",")}.flatten(1)]
  puts additional_aircraft
rescue
  additional_aircraft = {}
end
aircraft = copters.merge additional_aircraft

mysqlclient = Mysql2::Client.new(
  :host => ENV['MYSQLHOST'],
  :port => ENV['MYSQLPORT'],
  :username => ENV['MYSQLUSER'] || ENV['MYSQLUSERNAME'],
  :password => ENV['MYSQLPASSWORD'],
  :database => ENV['MYSQLDATABASE'] || "dump1090"
)
shingles_csv = CSV.open("shingles.csv", 'wb')

aircraft.each do |nnum, icao|
    results = mysqlclient.query(%{
      SELECT *, 
        convert_tz(parsed_time, '+00:00', 'US/Eastern') datetz, 
        conv(icao_addr, 10,16) as icao_hex
      FROM squitters 
      WHERE icao_addr = conv('#{icao}', 16,10) and 
        lat is not null
      order by parsed_time desc;}.gsub(/\s+/, " ").strip)
    puts "#{Time.now} results: #{results.count} (#{nnum} / #{icao})"

    next unless results.count > 0


    between_trajectory_interval = 15 # minutes
    # first, group by separate trajectories
    trajectories = results.reduce([]) do |memo, nxt_point, i|
        next [[nxt_point]] if memo.length  == 0
        if (memo[-1][-1]['datetz'] - nxt_point['datetz']) > between_trajectory_interval * 60 
            memo << [nxt_point]
        else
            memo[-1] << nxt_point
        end
        memo
    end

    trajectories.reject!{|traj| (traj[0]['datetz'] - traj[-1]['datetz']) < SHINGLE_DURATION_SECS}
    puts nnum
    puts "trajectories: #{trajectories.size}"
    puts "dates: " + trajectories.group_by{|traj| traj[0]['datetz'].strftime("%Y-%m-%d") }.map{|date, trajs| [date, trajs.size]}.sort_by{|date, cnt| date }.inspect
    puts "lengths: " + trajectories.group_by{|traj| (traj[0]['datetz'] - traj[-1]['datetz'])/60  }.map{|length_minutes, trajs| [length_minutes, trajs.size]}.sort_by{|length_minutes, cnt| length_minutes }.inspect



    # now shingle the trajectories
    shingled_trajectories = trajectories.map do |traj|
        traj_duration_secs = (traj[0]['datetz'] - traj[-1]['datetz']).abs 
        shingles_cnt = ((traj_duration_secs / (SHINGLE_DURATION_SECS)) * 2).to_i
        puts "shingles count: #{shingles_cnt} over #{(traj_duration_secs/60).to_i} min"
        shingles = (0..shingles_cnt).to_a.map do |i|
            shingle_start_elapsed_time = ((SHINGLE_DURATION_SECS/2.0) * i)
            shingle_end_elapsed_time  = ((SHINGLE_DURATION_SECS/2.0) * (i + 2))

            shingle_start_time = traj[-1]['datetz'] + shingle_start_elapsed_time # traj[-1] is the one that happened first.
            shingle_end_time = traj[-1]['datetz'] + shingle_end_elapsed_time # traj[-1] is the one that happened first.
            shingle_points = traj.select{|pt| pt['datetz'] >= shingle_start_time && pt['datetz'] <= shingle_end_time }

            shingle_points
        end
        shingles.reject!{|shingle| shingle.size < SHINGLE_MIN_POINTS }
        # shingles.reject!{|shingle| shingle_duration < SHINGLE_MIN_DURATION } # TODO!!
        shingles
    end

    # trajectories need a stable ID, as do shingles.
    # does NNum, icao hex and start, end times do it? I suppose, right?
    shingled_trajectories.each do |traj_shingles|
        traj_shingles.each do |shingle|
            next if shingle.length == 0
            shingle_start_time = shingle[-1]["parsed_time"].to_s.gsub(" -0500", '')
            shingle_end_time = shingle[0]["parsed_time"].to_s.gsub(" -0500", '')
            shingle_svg_fn = "hover_train_svg/#{shingle[0]["icao_hex"]}_#{shingle_start_time.gsub(/[ \:]/, '_')}_#{shingle_end_time.gsub(/[ \:]/, '_')}.svg"
            shingle_cmd = "node ../dump1090-mapper/mapify.js #{icao} #{nnum} '#{shingle_start_time}' '#{shingle_end_time}'"
            unless File.exists?(shingle_svg_fn) && File.new(shingle_svg_fn).size > 0
                puts shingle_cmd
                `#{shingle_cmd}` 
                File.rename("#{nnum}.svg", shingle_svg_fn)
            end
            shingle_png_fn = shingle_svg_fn.gsub("svg", "png")
            unless File.exists?(shingle_png_fn)
                chrome_cmd = "#{File.dirname(__FILE__)}/../dump1090-mapper/node_modules/puppeteer/.local-chromium/mac-624492/chrome-mac/Chromium.app/Contents/MacOS/Chromium --headless --window-size=600,600 --screenshot=#{shingle_png_fn} http://localhost:8000/#{shingle_svg_fn}  2>/dev/null"
                puts chrome_cmd
                begin
                    `#{chrome_cmd}`
                rescue e
                    puts "might be that headless chrome isn't accessible? change the path in training_data_maker.rb to point to a Chrome install, perhaps installed via npm install puppeteer"
                    raise e 
                end
            end
            shingles_csv << [shingle[0]["icao_hex"],
                    shingle_start_time,
                    shingle_end_time,
                    shingle_svg_fn, shingle_png_fn,
                    ] + shingle.map{|pt| [pt["lat"].to_f.round(6), pt["lon"].to_f.round(6)]}
        end
    end

    # svg_fn = `MAXTIMEDIFF=#{10} /usr/local/bin/node #{File.dirname(__FILE__)}/../dump1090-mapper/mapify.js #{icao} #{nnum}`
    # svg_fn.strip!
    # metadata_fn = svg_fn.gsub(".svg", ".metadata.json")
    # metadata = JSON.parse(open(metadata_fn, 'r'){|f| f.read })
    # neighborhood_names = metadata["nabes"] 
    # start_recd_time = metadata["start_recd_time"]
    # end_recd_time = metadata["end_recd_time"]
    # start_ac_time = metadata["start_ac_time"]
    # end_ac_time = metadata["end_ac_time"]
    # points_cnt = metadata["points_cnt"]



end

require 'mysql2'
require 'date'
require 'time'
require 'yaml'
require 'net/http'
require 'restclient'
require 'aws-sdk-s3'
require 'csv'
require 'fileutils'
require_relative "./utils"

# for all the copters
# generate shingled (i.e. overlapping) trajectories of NN minutes, let's say 5?
# and make a map of each of them
# so that I 
# can hand-label them as hovering or not.

FileUtils.mkdir_p("hover_train_svg")
FileUtils.mkdir_p("hover_train_png")

EXCLUDE_BACKGROUND = true

if __FILE__ == $0
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
        generate_shingles_for_trajectory(traj)
      end

      # trajectories need a stable ID, as do shingles.
      # does NNum, icao hex and start, end times do it? I suppose, right?
      shingled_trajectories.each do |traj_shingles|
          traj_shingles.each do |shingle|
              next if shingle.length == 0
              shingle_start_time = shingle[-1]["parsed_time"].to_s.gsub(/ -0\d00/, '')
              shingle_end_time = shingle[0]["parsed_time"].to_s.gsub(/ -0\d00/, '')

              shingle_png_fn, shingle_svg_fn = generate_shingle_map_from_shingle(shingle[0]["icao_hex"], nnum, shingle_start_time, shingle_end_time, EXCLUDE_BACKGROUND)

              client_count = shingle.map{|row| row["client_id"]}.uniq.count
              shingles_csv << [shingle[0]["icao_hex"],
                      shingle_start_time,
                      shingle_end_time,
                      shingle_svg_fn, shingle_png_fn,
                      client_count
                      ] + shingle.map{|pt| [pt["lat"].to_f.round(6), pt["lon"].to_f.round(6)]}
          end
      end
      puts shingled_trajectories.map{|t| t.size }.reduce(&:+)
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
end
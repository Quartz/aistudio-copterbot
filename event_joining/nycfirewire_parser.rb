require 'csv'

csv = CSV.open("Tweets by @NYCFireWire - Sheet1.csv")

output_csv = CSV.open("NYCFireWire_tweets.csv", 'w')
output_csv << ["date", "acct", "tweet", "url", "street_addr", "boro", "state", "zip"]

csv.each do |row|
	tweet = row[2]
	tweet.gsub!(/\*All Hands\*/, '')
	tweet.gsub!(/\*\*?\d+-\d+-\d+\*\*?/, '')
	tweet.gsub!(/\*\*?\d+-\d+\*\*?/, '')
	tweet.gsub!(/\*(CO Emergency|\d.. Alarm|Air Mail|Unusual Incident|Subway Emergency|Collapse|10-60\/Major Emergency|Confined Space|MVA\/Pin|HazMat|MVA\/Overturned|Car vs Bldg|Mutual Aide|Traffic|Other|Tech Rescue|Crane Collapse|Water Rescue)\*?/, '')

	regex = /(Queens|Brooklyn|Staten Island|Manhattan|Bronx) +(?:Box \d+ ?\.? ?)? *(\d+(?:-\d+)? .*? (?:Ave|Avenue|Blvd|Boulevard|Dr|Drive|St|Street|Pl|Place|Rd|Road|Concourse|Ct|Pkwy|Parkway|Plaza|Broadway|Lane|Ln)[ \.,])/i
	md = regex.match(tweet)
	# puts tweet unless md
	next unless md
	output_csv << row + (md ? [md[2].strip.gsub(/[\.,]$/, ''), md[1].strip.gsub(/[\.,]$/, ''), "NY", ''] : ['', '', '', ''])
end
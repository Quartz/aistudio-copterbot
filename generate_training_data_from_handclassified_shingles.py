import csv
from os.path import join, basename, exists
from os import environ
import pandas as pd
import sklearn
import numpy as np
import mysql.connector as mysql
from functools import reduce
from itertools import groupby
from collections import Counter
from math import sqrt, floor,  sin, cos, sqrt, atan2, radians

from datetime import datetime, timedelta
# FEATURE SELECTION
#
# Let's figure out some things that might be helpful...
#
# the buzzfeed categories I'm using as a starting point, but some of them are per *aircraft* not per *flight*.
# Buzzfeed: https://github.com/BuzzFeedNews/2017-08-spy-plane-finder/blob/master/index.Rmd

copters = {
  "N917PD": "ACB1F5",
  "N918PD": "ACB5AC",
  "N919PD": "ACB963",
  "N920PD": "ACBF73",
  "N319PD": "A36989",
  "N422PD": "A50456",
  "N414PD": "A4E445",
  "N23FH" : "A206AC",
  "N509PD": "A65CA8",
}

copters = {v: k for k, v in copters.items()}

folders = {
  "all": ["hover_train_png_all", "hover_train_png_more", "hover_train_png_even_more"],
  "hover": ["hover_train_png_more_hover_only", "hover_train_png_hover_only", "hover_train_png_even_more_hover_only",]
}

db = mysql.connect(
    host = environ.get('MYSQLHOST', None),
    # port = environ.get('MYSQLPORT', None),
    user = environ.get('MYSQLUSER', environ.get('MYSQLUSERNAME', None)),
    database = environ.get('MYSQLDATABASE', "dump1090"),
    password = environ.get('MYSQLPASSWORD', None)
)
cursor = db.cursor(dictionary=True)

def haversine(lat1, lon1, lat2, lon2):
  """ calculate the distance betweent two lat/lon points."""
  assert lat1 and lon1 and lat2 and lon2
  lon1, lat1, lon2, lat2 = map(radians, [lon1, lat1, lon2, lat2])
  R = 3958.8 # approximate radius of earth in miles
  dlon = lon2 - lon1
  dlat = lat2 - lat1
  a = sin(dlat / 2)**2 + cos(lat1) * cos(lat2) * sin(dlon / 2)**2
  c = 2 * atan2(sqrt(a), sqrt(1 - a))
  return R * c


# see mapify.js for explanation.
def sort_rows_by_corrected_time(rows):
  rows_by_client = {k: list(g) for k, g in groupby(sorted(rows, key=lambda row: row["client_id"]), lambda row: row["client_id"])}
  
  any_time_by_client = [[client_id, rows_by_client[client_id][0]['generated_datetime']] for client_id in rows_by_client.keys()]
  # TODO: adapt this to match the JS below
  # var unique_client_ids = [...new Set(_(rows).map(function(row){ return row["client_id"]}))]; 
  # var one_time_per_client = Object.entries(_(rows).reduce(function(memo, row){
  #   if( _.some(unique_client_ids, function(client_id){ return !memo[client_id] }) ){
  #     memo[row["client_id"]] = row["generated_datetime"]
  #   }
  #   return memo;
  # }, {}))



  first_client = any_time_by_client.pop()
  def hour_diff_from(acc, client_id_time):
    acc.append([client_id_time[0], floor(((client_id_time[1] - first_client[1]).total_seconds() + 60 * 10) / 60 / 60) ]) 
    return acc
  hour_differences = {client_id: hour_diff for client_id, hour_diff in reduce(hour_diff_from, any_time_by_client, [[first_client[0], 0]])}

  for row in rows:
    row["corrected_time"] = row["generated_datetime"] - timedelta(hours=hour_differences[row["client_id"]])
  return sorted(rows, key=lambda row: row["corrected_time"], reverse=True)

def bucketize(buckets, key):
  assert buckets[0] < buckets[1] and buckets[1] < buckets[2] and buckets[2] < buckets[3] and buckets[3] < buckets[4]
  def _bucketizer(memo, row):
    if key not in row or row[key] is None:
      return memo
    if row[key] < buckets[0]:
      memo[0] += 1
    elif row[key] < buckets[1]:
      memo[1] += 1
    elif row[key] < buckets[2]:
      memo[2] += 1
    elif row[key] < buckets[3]:
      memo[3] += 1
    elif row[key] < buckets[4]:
      memo[4] += 1
    elif row[key] >= buckets[4]:
      memo[5] += 1
    return memo
  return _bucketizer

def pair_up(rows, fieldname):
  """ Combine rows to get all fields in one record

    Due to the structure of the ADSB protocol, rows have EITHER position or speed/steer/etc.
    This combines rows so that the new fake rows have both.
  """
  def _pair_up (memo, row):
    if row["lon"]:
      memo["last_lon"] = row
    if row[fieldname]:
      memo["last_of_interest"] = row
    if memo["last_lon"] and memo["last_of_interest"] and abs(memo["last_lon"]["parsed_time"] - memo["last_of_interest"]["parsed_time"]).total_seconds() < 10:
      memo["pairs"].append({"lat": memo["last_lon"]["lat"], "lon": memo["last_lon"]["lon"], "corrected_time": memo["last_lon"]["corrected_time"], fieldname: memo["last_of_interest"][fieldname]})
      memo["last_lon"] = None
      memo["last_of_interest"] = None
    return memo
  viable_rows = reduce(_pair_up, rows, {"last_lon": None, "last_of_interest":  None, "pairs": []})["pairs"]
  return viable_rows


def speed_buckets(rows):
  # - `speed1`,`speed2`,`speed3`,`speed4`,`speed5` Proportion of `speed` values recorded for the aircraft falling into each of five quantiles recorded for `speed` for the sample of 500 planes.
  # these quantile values are derived via quantiles_maker.rb
  return reduce(bucketize([45, 61, 74, 85, 100], "ground_speed"), rows, [0] * 6)

def steer_buckets(rows):
  # - `steer1`,`steer2`,`steer3`,`steer4`,`steer5`,`steer6`,`steer7`,`steer8` Proportion of `steer` values for each aircraft falling into bins set manually, after observing the distribution for the sample of 500 planes, using the breaks: -180, -25, -10, -1, 0, 1, 22, 45, 180.
  return reduce(bucketize([33, 112, 187, 225, 282], "track"), rows, [0] * 6)

def vertical_rate_buckets(rows):
  return reduce(bucketize([-192, -64, 0, 64, 192], "vertical_rate"), rows, [0] * 6)

def altitude_buckets(rows):
# - `altitude1`,`altitude2`,`altitude3`,`altitude4`,`altitude5` Proportion of `altitude` values recorded for the aircraft falling into each of five quantiles recorded for `altitude` for the sample of 500 planes.
  return reduce(bucketize([325, 475, 650, 800, 1050], "altitude"), rows, [0] * 6)

def distance_traveled_versus_point_to_point_buckets(reversed_rows):
  """ How efficient was the copter's trip from point A to point B?

     per minute, per two minute shingle, three minute shingle and four minute shingle and total
     aka "efficiency" -- how efficient of a path did the helicopter take to get between point a and point b?
     so can I look at the relationship between speed at point a to distance/time between a and b?
  """
  assert reversed_rows[0]["corrected_time"] >= reversed_rows[1]["corrected_time"] and reversed_rows[0]["corrected_time"] >= reversed_rows[-1]["corrected_time"]

  # a = len([r for r in reversed_rows if r["ground_speed"]])
  # b = len([r for r in reversed_rows if r["lat"]])

  reversed_rows = pair_up(reversed_rows, "ground_speed")

  # print(a, b, len(reversed_rows))

  if len(reversed_rows) == 0:
    return [0] * 6

  # print(len([r for r in reversed_rows if r["ground_speed"] and r["lat"]]), len(reversed_rows))

  shingles = [[(start, start + 30), (start, start + 60), ( start, start + 90)] for start in range(0, 300, 30)]
  shingles = [s for l in shingles for s in l]
  shingles = [s for s in shingles if s[1] <= 300 ]
  rows = [r for r in reversed_rows]; rows.reverse()
  start_time = rows[0]["corrected_time"]
  shingle_rows = {} # finding the row that's closest to each shingle point, so we only have to do that once
  for timepoint in set([s for l in shingles for s in l]): # e.g. 30, 60, 90
    first_after_timepoint = next((row for row in rows if (row["corrected_time"] - start_time).total_seconds() > timepoint), None )
    first_before_timepoint = next((row for row in reversed_rows if (row["corrected_time"] - start_time).total_seconds() > timepoint), None)
    if not first_after_timepoint or not first_before_timepoint:
      continue
    shingle_rows[timepoint] = first_before_timepoint if abs((first_before_timepoint["corrected_time"] - start_time).total_seconds() - timepoint) < abs((first_after_timepoint["corrected_time"] - start_time).total_seconds() - timepoint) else first_after_timepoint

  proportions = []
  for shingle in shingles:
    first_row = shingle_rows.get(shingle[0], None)
    second_row = shingle_rows.get(shingle[1], None)
    if not first_row or not second_row:
      continue
    actual_distance = haversine(first_row["lat"], first_row["lon"], second_row["lat"], second_row["lon"])
    time_diff = (second_row["corrected_time"] - first_row["corrected_time"]).total_seconds()
    possible_distance = first_row["ground_speed"] * (time_diff / (60 * 60)) 
    # possible_distance is probably in nautical miles and actual_distance is in statute miles
    # it doesn't *matter* (because a ratio's a ratio) but it'll _slightly_ mess up our buckets here.
    if possible_distance == 0:
      continue
    proportion = actual_distance / float(possible_distance)
    # print(actual_distance, possible_distance, proportion)
    proportions.append({"p": proportion})
  return reduce(bucketize([0.42537939316751366, 0.828295700891338, 1.0607740576490772, 1.1439016121508359, 1.2128166596687067], "p"), proportions, [0] * 6)

def point_distances_from_centerpoint(rows):  
  lats, lons = list(map(list, zip(*[[row["lat"], row["lon"]] for row in rows if row["lat"]])))
  avg_lat = sum(lats) / len(lats)
  avg_lon = sum(lons) / len(lons)
  dists = [{"dist": haversine(avg_lat, avg_lon, row["lat"], row["lon"])} for row in rows if row["lat"]]
  # for dist in dists:
  #   print(dist["dist"])
  return reduce(bucketize([0.175, 0.348, 0.560, 0.88, 1.47], "dist"), dists, [0] * 6)


def steer_compared_to_x_y(rows): # (to find when it's hovering in one exact spot)

  viable_rows = pair_up(rows, "track")
  stuff = [{"a": abs(a["track"] - b["track"]) / max(0.0001, haversine(a["lat"], a["lon"], b["lat"], b["lon"]) )} for a, b in zip(viable_rows[:-1], viable_rows[1:]) ]

  # for a in stuff:
  #   print(a["a"])

  # these quintiles modified from [10000, 20000, 60000, 140000, 280000] to create more distinction at the high end.
  return reduce(bucketize([10, 29, 83, 185, 461], "a"), stuff, [0] * 6)
  # return reduce(bucketize(, "a"), stuff, [0] * 6)

def top_squawk(rows):
  squawks = [row["decimal_squawk"] for row in rows if row["decimal_squawk"] is not None]
  if len(squawks) == 0:
    return ['-1']
  return [Counter(squawks).most_common(1)[0][0]]

def bucket_headers(word):
  return [word + str(i + 1) for i in range(6)]

import csv
with open("training_data.csv", 'w') as csvout:
  training_data = csv.writer(csvout)
  training_data.writerow(["icao_hex", "nnum", "png_filename", "start_time", "end_time", "is_hover", "record_cnt"] + bucket_headers("speed") + bucket_headers("steer") + bucket_headers("vertical_rate") + bucket_headers("altitude") +[ "squawk"] + bucket_headers("xysteer")  + bucket_headers("dist_from_ctr") + bucket_headers("circly_ratio") )
  with open("shingles.csv") as csvin:
    shingles_reader = csv.reader(csvin)
    for row in shingles_reader:
      icao_hex, shingle_start_time, shingle_end_time, shingle_svg_fn, shingle_png_fn, client_count, *points = row

      if not any(map(lambda folder: exists(join("hand_coded_training_data", folder, basename(shingle_png_fn))), folders['all'])):
        print("missing file {}".format(shingle_png_fn))
        continue
      else:
        shingle_png_fn = next(join("hand_coded_training_data", folder, basename(shingle_png_fn)) for folder in folders['all'] if exists(join("hand_coded_training_data", folder, basename(shingle_png_fn))))

      is_hover = any(map(lambda folder: exists(join("hand_coded_training_data", folder, basename(shingle_png_fn))), folders['hover']))

      query = "select * from squitters where conv(%s, 16,10) = icao_addr and parsed_time >= %s and parsed_time <= %s order by parsed_time"

      # print(query.replace("%s", "{}").format(icao_hex, shingle_start_time, shingle_end_time))
      cursor.execute(query, [icao_hex, shingle_start_time, shingle_end_time])
      records = cursor.fetchall()
      assert len(points) <= len(records)
      if len(records) == 0:
        continue
      records = sort_rows_by_corrected_time(records)
      features = [len(records)] + speed_buckets(records) + steer_buckets(records) + vertical_rate_buckets(records) + altitude_buckets(records) + top_squawk(records) + steer_compared_to_x_y(records) + point_distances_from_centerpoint(records) + distance_traveled_versus_point_to_point_buckets(records)

      training_data.writerow([icao_hex, copters[icao_hex], shingle_png_fn, shingle_start_time, shingle_end_time, is_hover] + features)
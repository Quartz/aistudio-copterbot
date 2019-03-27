import csv
from os.path import join, basename, exists
from os import environ
import pandas as pd
import sklearn
import numpy as np
import mysql.connector as mysql
from functools import reduce
from collections import Counter
from math import sqrt
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
  "all": ["hover_train_png_all", "hover_train_png_more"],
  "hover": ["hover_train_png_more_hover_only", "hover_train_png_hover_only"]
}

db = mysql.connect(
    host = environ.get('MYSQLHOST', None),
    # port = environ.get('MYSQLPORT', None),
    user = environ.get('MYSQLUSER', environ.get('MYSQLUSERNAME', None)),
    database = environ.get('MYSQLDATABASE', "dump1090"),
    password = environ.get('MYSQLPASSWORD', None)
)
cursor = db.cursor(dictionary=True)

def bucketize(buckets, key):
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
    return memo
  return _bucketizer

def speed_buckets(rows):
  # - `speed1`,`speed2`,`speed3`,`speed4`,`speed5` Proportion of `speed` values recorded for the aircraft falling into each of five quantiles recorded for `speed` for the sample of 500 planes.
  # these quantile values are derived via quantiles_maker.rb
  return reduce(bucketize([45, 61, 74, 85, 100], "ground_speed"), rows, [0] * 5)

def steer_buckets(rows):
  # - `steer1`,`steer2`,`steer3`,`steer4`,`steer5`,`steer6`,`steer7`,`steer8` Proportion of `steer` values for each aircraft falling into bins set manually, after observing the distribution for the sample of 500 planes, using the breaks: -180, -25, -10, -1, 0, 1, 22, 45, 180.
  return reduce(bucketize([33, 112, 187, 225, 282], "track"), rows, [0] * 5)

def vertical_rate_buckets(rows):
  return reduce(bucketize([-192, -64, 0, 64, 192], "vertical_rate"), rows, [0] * 5)

def altitude_buckets(rows):
# - `altitude1`,`altitude2`,`altitude3`,`altitude4`,`altitude5` Proportion of `altitude` values recorded for the aircraft falling into each of five quantiles recorded for `altitude` for the sample of 500 planes.
  return reduce(bucketize([325, 475, 650, 800, 1050], "altitude"), rows, [0] * 5)

def distance_traveled_versus_point_to_point_buckets(rows):
  # per minute, per two minute shingle, three minute shingle and four minute shingle and total
  # aka "efficiency" -- how efficient of a path did the helicopter take to get between point a and point b?
  # so can I look at the relationship between speed at point a to distance/time between a and b?
  return []


def steer_compared_to_x_y(rows): # (to find when it's hovering in one exact spot)
  def _asdf (memo, row):
    if row["lon"]:
      memo["last_lon"] = row
    if row["track"]:
      memo["last_track"] = row
    if memo["last_lon"] and memo["last_track"]:
      memo["pairs"].append({"lat": memo["last_lon"]["lat"], "lon": memo["last_lon"]["lon"], "track": memo["last_track"]["track"]})
    return memo

  viable_rows = reduce(_asdf,rows, {"last_lon": None, "last_track":  None, "pairs": []})["pairs"]
  # print([sqrt(((a["lat"] - b["lat"]) ** 2) + ((a["lon"] - b["lon"]) ** 2)) for a, b in zip(viable_rows[:-1], viable_rows[1:]) ])
  stuff = [{"a": abs(a["track"] - b["track"]) / max(0.0001, sqrt(((a["lat"] - b["lat"]) ** 2) + ((a["lon"] - b["lon"]) ** 2)))} for a, b in zip(viable_rows[:-1], viable_rows[1:]) ]

  for a in stuff:
    print(a["a"])
  # if stuff:
  #   print((max([a["a"] for a in stuff]), min([a["a"] for a in stuff])))
  # else: 
  #   print(len(viable_rows))
  return reduce(bucketize([-240000, -70000, 0, 70000, 240000], "a"), stuff, [0] * 5)

def top_squawk(rows):
  squawks = [row["decimal_squawk"] for row in rows if row["decimal_squawk"] is not None]
  if len(squawks) == 0:
    return ['-1']
  return [Counter(squawks).most_common(1)[0][0]]

def bucket_headers(word):
  return [word + str(i + 1) for i in range(5)]

import csv
with open("training_data.csv", 'w') as csvout:
  training_data = csv.writer(csvout)
  training_data.writerow(["icao_hex", "nnum", "start_time", "end_time", "is_hover", "record_cnt"] + bucket_headers("speed") + bucket_headers("steer") + bucket_headers("vertical_rate") + bucket_headers("altitude") +[ "squawk"] + bucket_headers("xysteer") )
  with open("shingles.csv") as csvin:
    shingles_reader = csv.reader(csvin)
    for row in shingles_reader:
      icao_hex, shingle_start_time, shingle_end_time, shingle_svg_fn, shingle_png_fn, client_count, *points = row

      if not any(map(lambda folder: exists(join("hand_coded_training_data", folder, basename(shingle_png_fn))), folders['all'])):
        raise Exception("missing file `#{shingle_png_fn}`")
      is_hover = any(map(lambda folder: exists(join("hand_coded_training_data", folder, basename(shingle_png_fn))), folders['hover']))

      query = "select * from squitters where conv(%s, 16,10) = icao_addr and parsed_time >= %s and parsed_time <= %s order by parsed_time"
      # TODO: order these with the corrected time from Node
      # print(query.replace("%s", "{}").format(icao_hex, shingle_start_time, shingle_end_time))
      cursor.execute(query, [icao_hex, shingle_start_time, shingle_end_time])
      records = cursor.fetchall()
      assert len(points) <= len(records)
      features = [len(records)] + speed_buckets(records) + steer_buckets(records) + vertical_rate_buckets(records) + altitude_buckets(records) + top_squawk(records) + steer_compared_to_x_y(records)

      training_data.writerow([icao_hex, copters[icao_hex], shingle_start_time, shingle_end_time, is_hover] + features)
import time
import yaml
import requests
import pymysql.cursors
from os import makedirs, rename, environ
from os.path import join, dirname, basename, abspath
from map_classifier import MapClassifier
from datetime import datetime
from random import choice
import traceback
import json
from sys import path
path.append('../dump1090mapper')
from dump1090mapper.flightpath import Flightpath, NeighborhoodsCounter, COPTERS, HelicopterShinglingError, HelicopterMappingError
import boto3
import tweepy

# TODO.

aircraft = {
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

env = lambda x: environ.get(x, None)

prod_mapping_interval = 10  # min, should be 15
dev_mapping_interval = 15
MAPPING_INTERVAL = (env('MAPINTVL') or dev_mapping_interval) if env("NEVERTWEET") or env("NEVERTOOT") else (env('MAPINTVL') or prod_mapping_interval)
delay = 0 # min, default 5 min

MIN_POINTS = 3 # number of points to require before tweeting a map. probably actually ought to be more!

BUCKET = 'qz-aistudio-jbfm-scratch'

map_classifier = MapClassifier()

def check_if_helicopter_has_been_seen_recently(connection, nnum, icao):
    with connection.cursor() as cursor:
        # Create a new record
        sql = f"""
        SELECT *, convert_tz(parsed_time, '+00:00', 'US/Eastern') datetz 
              FROM squitters 
              WHERE icao_addr = conv('{icao}', 16,10) and 
                lat is not null and 
                convert_tz(parsed_time, '+00:00', 'US/Eastern') > DATE_SUB(convert_tz(NOW(), '+00:00', 'US/Eastern'), interval {MAPPING_INTERVAL} minute) and 
                convert_tz(parsed_time, '+00:00', 'US/Eastern') < convert_tz(NOW(), '+00:00', 'US/Eastern') 
              order by parsed_time desc;""".replace(r"\s+", " ").strip()
        cursor.execute(sql)
        results = cursor.fetchall()

    print(f"{datetime.now()} results: {len(results)} ({nnum} / {icao})")
    return len(results) >= MIN_POINTS

creds = yaml.safe_load(open(join(dirname(__file__), "creds.yml")))
if not env('NEVERTWEET'):
    auth = tweepy.OAuthHandler(creds["twitter"]["consumer_key"], creds["twitter"]["consumer_secret"])
    auth.set_access_token(creds["twitter"]["token"], creds["twitter"]["secret"])
    twitterclient = tweepy.API(auth)

PNG_PATH = "/tmp/hover/"
makedirs(PNG_PATH, exist_ok=True)


message_templates = [
  "Sorry you got woken up… NYPD helicopter ~NNUM~ has been hovering over ~HOVERNEIGHBORHOODS~ from about ~TIME1~ to ~TIME2~. Do you have any idea why? Reply and let us know.",
  "You aren’t imagining it, that helicopter has been there a while. We’ve detected that NYPD helicopter ~NNUM~ has been hovering over ~HOVERNEIGHBORHOODS~ for ~DURATION~. We want to find out why. Do you know? Tell us!",
  "Welp, ~HOVERNEIGHBORHOODS~, that helicopter has been hovering there for a while, no? Got a clue what’s happening nearby that NYPD is responding to? Tell us!",
  "CHOP CHOP chop chop … [silence] … chop chop chop … [silence] … chop CHOP CHOP.\n\n That police helicopter’s been hovering over ~HOVERNEIGHBORHOODS~ since ~TIME1~… Wonder what it’s up to? Stay tuned. If you know, say so below (plz!).",
  "CHOP CHOP chop chop … [silence] … chop chop chop … [silence] … chop CHOP CHOP.\n\n That police helicopter’s been hovering overhead since ~TIME1~… Wonder what it’s up to? Stay tuned. If you know, say so below (plz!).",
  "There’s an NYPD helicopter hovering over ~BRIDGENAME~. Probably traffic, but maybe not. Do you know what’s happening?",
]



def andify(items):
    if len(items) == 0:
        return ''
    if len(items) == 1:
        return items[0]
    joined = ", ".join(items[:-1])
    return f"{joined} and {items[-1]}"



def construct_tweet_text(**kwargs):
    if "PD" not in kwargs["nnum"]: # don't tweet non-police aircraft
        return 

    tweet_candidates = list(message_templates)
    if len(kwargs["hover_neighborhood_names"]) == 0:
        tweet_candidates = [text for text in tweet_candidates if "NEIGHBORHOODS~" not in text]
    if len(kwargs["bridge_names"]) == 0:
        tweet_candidates = [text for text in tweet_candidates if "~BRIDGENAME~" not in text]
    tweet_text = str(choice(tweet_candidates))

    if not kwargs["currently_hovering"]:
        tweet_text = tweet_text.replace("has been", "was")
        tweet_text = tweet_text.replace("’s been", " was")
        tweet_text = tweet_text.replace("There’s", "There was")

    while len(kwargs["hover_neighborhood_names"]) > 0:
        possible_tweet_text = tweet_text.replace("~HOVERNEIGHBORHOODS~", andify(kwargs["hover_neighborhood_names"]) )
        if len(possible_tweet_text) < 280:
            tweet_text = possible_tweet_text
            break
        else:
            kwargs["hover_neighborhood_names"].pop()

    # this is only for tweeting when it ISN"T hovering, which we're not doing in this Python iteration.
    # else: # older style text.
    #     assert False, "this doesn't work at all"
    #     if not neighborhood_names or "PD" not in kwargs["nnum"]:
    #         tweet_text =  str(choice(messages)) if "PD" in kwargs["nnum"] else non_pd_msg
    #     else:
    #         tweet_text = str(choice(messages_with_neighborhoods))
    #         while len(neighborhood_names) > 0:
    #             possible_tweet_text = tweet_text.replace("~NEIGHBORHOODS~", andify(neighborhood_names) )
    #             if len(possible_tweet_text) < 280:
    #                 tweet_text = possible_tweet_text
    #                 break
    #             else:
    #                 neighborhood_names.pop()

    tweet_text = tweet_text.replace("~NNUM~", kwargs["nnum"])
    tweet_text = tweet_text.replace("~TIME1~", kwargs["earliest_time_seen"].strftime("%-I:%M %p") )
    tweet_text = tweet_text.replace("~TIME2~", kwargs["latest_time_seen"].strftime("%-I:%M %p") )
    duration_min = (kwargs["latest_time_seen"] - kwargs["earliest_time_seen"]).total_seconds() // 60
    tweet_text = tweet_text.replace("~DURATION~", kwargs["flight_duration"] + " min" )
    tweet_text = tweet_text.replace("~BRIDGENAME~", andify(kwargs["bridge_names"]))

    debug_text = "{} points; {} to {}".format(kwargs["points_cnt"], kwargs["earliest_time_seen"].strftime("%-I:%M %p"), kwargs["latest_time_seen"].strftime("%-I:%M %p"))
    
    image_caption =  "A map of {}'s flight over the NYC area.".format(kwargs["nnum"])
    return (tweet_text, debug_text, image_caption)

def tweet(tweet_text, debug_text, png_fn, latest_shingle_centerpoint=None):
    if not env("NEVERTWEET"):
        if latest_shingle_centerpoint:
            twitterclient.update_with_media(png_fn, tweet_text, lat=latest_shingle_centerpoint['lat'], long=latest_shingle_centerpoint['lon'])
        else:
            twitterclient.update_with_media(png_fn, tweet_text)
        print("actually twote (from python)")
    else:
        print("not really tweeting")
def toot(tweet_text, debug_text, png_fn):
    if not env("NEVERTOOT"):
        media_json = requests.post("{}/api/v1/media".format(creds['botsinspace']["instance"]), 
            files={"file": open(png_fn, 'rb')}, 
            headers={"Authorization": "Bearer {}".format(creds["botsinspace"]["access_token"])}
            )
        media =  media_json.json()
        status_json = requests.post("{}/api/v1/statuses".format(creds['botsinspace']["instance"]), 
            data={"status": tweet_text, "media_ids": [media["id"]], "visibility": "public"}, 
            headers={"Authorization": "Bearer {}".format(creds["botsinspace"]["access_token"])})
        print("actually tooted (from python)")
      # TODO
    else:
      print("but not really tooting")

def post_to_slack(tweet_text, debug_text, png_fn, image_caption):
    if not env('NEVERSLACK'):
        png_s3_key = upload_image_to_s3(png_fn)
        if not png_s3_key: #there's been an error

            print("error uploading to S3, decided not to Slack the msg")
            return 
        slack_payload =  {
          "text": tweet_text + " \n " + debug_text,
          "attachments": [
                {
                    "fallback": image_caption,
                    "image_url": f"http://{BUCKET}.s3.amazonaws.com/{png_s3_key}",
                }
            ]
        }
        print("posting to slack (from python)")
        resp = requests.post(creds['slack']['webhook'], data=json.dumps(slack_payload), headers={"Content-Type": "application/json"})
    else:
        print("but not actually posting to Slack")
def upload_image_to_s3(png_fn):
    # uploading the image to S3, for Slack.
    s3_client = boto3.client('s3')

    png_s3_base_key = basename(png_fn)
    png_s3_key = "airplanes/" + png_s3_base_key #.replace(".png", '') + png_datetime +  ".png"

    try:
        response = s3_client.upload_file(png_fn, BUCKET, png_s3_key,
            ExtraArgs={'ACL': 'public-read', 'ContentType': "image/png"})
    except boto3.ClientError as e:
        logging.error(e)
        return False
    return png_s3_key

def notify(tweet_ingredients, if_it_hovered):
    print("tweet ingredients", tweet_ingredients)
    if not env("ONLY_TWEET_HOVERS") or if_it_hovered:
        tweet_text, debug_text, image_caption = construct_tweet_text(**tweet_ingredients)
        print(f"trying to tweet \"{tweet_text}\" in {delay} min")
        print(f"debug text: {debug_text}")
        if not env("NEVERTWEET") or not env("NEVERTOOT"):
          time.sleep(delay * 60)


        tweet(tweet_text, debug_text, tweet_ingredients["png_fn"], tweet_ingredients["latest_shingle_centerpoint"])
        toot(tweet_text, debug_text, tweet_ingredients["png_fn"])
        post_to_slack(tweet_text, debug_text, tweet_ingredients["png_fn"], image_caption)

        print(f"done at {datetime.now()}")
        print("\n")
        print("\n")

if __name__ == "__main__":
    connection = pymysql.connect(host=env('MYSQLHOST'),
                                 user=env('MYSQLUSER') or env('MYSQLUSERNAME'),
                                 port=env('MYSQLPORT'),
                                 password=env('MYSQLPASSWORD'),
                                 db=env('MYSQLDATABASE') or "dump1090",
                                 charset='utf8mb4',
                                 cursorclass=pymysql.cursors.DictCursor)


    for nnum, icao_hex in aircraft.items():
      try:
        # parsed_time is the current time on the rpi, so regardless of the garbage given by the airplane, that should work
        # however, it causes some NYPD helicopters to be tweeted too much
        # but without it, n725dt is never tweeted
        # TODO: should I modify dump1090-stream-parser so that one of the timing columns is current time on the DB? (e.g. with MYSQL @@current_time or whatever)

        if not check_if_helicopter_has_been_seen_recently(connection, nnum, icao_hex):
            continue

        crs = 2263 # NY State Plane
        flightpath = Flightpath(icao_hex, nnum, crs=crs)
        fp_json = flightpath.to_json()
        with open(flightpath.json_fn(), 'w') as f:
            print("writing JSON to " + flightpath.json_fn())
            f.write(fp_json)
        try:
            shingles = list(flightpath.as_shingles())

            for shingle in shingles:
                shingle.to_map(include_labels=False)
                shingle.is_hovering = map_classifier.classify_map(shingle.get_map_fn())

        except HelicopterShinglingError:
            print("HelicopterShinglingError")
            shingles = []

        was_hovering = any(shingle.is_hovering for shingle in shingles)
        currently_hovering = any(shingle.is_hovering for shingle in shingles[-2:])


        print("was hovering!" if was_hovering else "wasn't hovering")

        if was_hovering:
            centerpoint_of_last_hovering_shingle = next(shingle for shingle in reversed(shingles) if shingle.is_hovering).centerpoint()

            map_fn, _ = flightpath.to_map(arbitrary_marker=(centerpoint_of_last_hovering_shingle["lat"],centerpoint_of_last_hovering_shingle["lon"]), background_color='#ADD8E6')
            flight_duration_mins = int((flightpath.end_time - flightpath.start_time).total_seconds() // 60)
            duration_str =  f"{flight_duration_mins // 60} hours and {flight_duration_mins % 60} mins" if flight_duration_mins > 120 else (f"{flight_duration_mins // 60} hour and {flight_duration_mins % 60} mins" if flight_duration_mins > 60 else f"{flight_duration_mins} mins")

            print(f"CONVERT those times to local: {flightpath.start_time} {flightpath.end_time}")

            hover_neighborhood_names = list(set([item.replace("Brg", "Bridge") for sl in [shingle.neighborhoods_underneath() for shingle in shingles if shingle.is_hovering] for item in sl]))
            tweet_ingredients = {
                "nnum": flightpath.nnum,
                "hover_neighborhood_names": hover_neighborhood_names,
                "bridge_names": [name for name in hover_neighborhood_names if "Bridge" in name and name.index("Bridge") == len(name) - 6],
                "currently_hovering": currently_hovering,
                "latest_time_seen": flightpath.end_time,
                "earliest_time_seen": flightpath.start_time,
                "flight_duration": duration_str,
                "png_fn": map_fn,
                "points_cnt": flightpath.points_cnt,
                "latest_shingle_centerpoint": centerpoint_of_last_hovering_shingle,

            }
            notify(tweet_ingredients, was_hovering)
      except Exception as e:
        print(e)
        traceback.print_exc()
    connection.close()


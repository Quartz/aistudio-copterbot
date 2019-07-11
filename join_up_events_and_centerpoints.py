import csv
from math import radians, cos, sin, asin, sqrt
from datetime import datetime
from collections import Counter
import json 
import time 
from pytz import timezone

def haversine(lon1, lat1, lon2, lat2):
    """
    Calculate the great circle distance between two points 
    on the earth (specified in decimal degrees)
    """
    # convert decimal degrees to radians 
    lon1, lat1, lon2, lat2 = map(radians, [lon1, lat1, lon2, lat2])

    # haversine formula 
    dlon = lon2 - lon1 
    dlat = lat2 - lat1 
    a = sin(dlat/2)**2 + cos(lat1) * cos(lat2) * sin(dlon/2)**2
    c = 2 * asin(sqrt(a)) 
    r = 3956 # Radius of earth in mi. Use 6371 for km
    return c * r


distance = 1 #mi
timedist = 60 #min

events_by_date = {}
# "date","acct","tweet","url","street_addr","boro","state","AUTO_UNIQUE_ID_2019-05-11_Jeremybmerrill_NYCFireWire_tw","Source","TimeTaken","UpdatedGeocoding","Version","ErrorMessage","TransactionId","naaccrQualCode","naaccrQualType","FeatureMatchingResultType","MatchedLocationType","RegionSizeUnits","InterpolationType","RegionSize","InterpolationSubType","FeatureMatchingGeographyType","MatchScore","FeatureMatchingHierarchy","TieHandlingStrategyType","FeatureMatchingResultTypeTieBreakingNotes","GeocodeQualityType","FeatureMatchingHierarchyNotes","FeatureMatchingResultTypeNotes","FeatureMatchingResultCount","Latitude","Longitude","MatchType"

with open("NYCFireWire_tw.csv") as events_csvfile:
    for event in  csv.DictReader(events_csvfile):
        date = datetime.strptime(event["date"].split("at")[0].strip(), '%B %d, %Y').strftime('%Y-%m-%d')
        time = event["date"].split("at")[1]
        if event["Latitude"] == '0':
            continue
        if date not in events_by_date: 
            events_by_date[date] = []
        events_by_date[date].append(event)

result = Counter()
same_hour_result = Counter()
with open("centerpoints.csv") as centerpoints_csvfile:
    centerpoints_csv = csv.reader(centerpoints_csvfile)
    centerpoints = list(centerpoints_csv)
    for centerpoint_row in centerpoints:
        if centerpoint_row[-1] == "nonhover":
            continue
        centerpoint_date = datetime.strptime(centerpoint_row[1][:10], '%Y-%m-%d').replace(tzinfo=timezone('UTC'))
        try:
            candidate_events = events_by_date[centerpoint_date.strftime('%Y-%m-%d')]
        except KeyError:
            candidate_events = []
            continue
        # if start_time > midnight:
        #   candidate_events += events_by_date[date + 1]
        print(len(candidate_events))
        centerpoint_datetime = datetime.strptime(centerpoint_row[1], '%Y-%m-%d %H:%M:%S').replace(tzinfo=timezone('UTC'))
        candidate_events = [event for event in candidate_events if abs((datetime.strptime(event["date"].strip(), '%B %d, %Y at %I:%M%p').replace(tzinfo=timezone('US/Eastern')) - centerpoint_datetime).total_seconds()) < timedist * 60]
        same_hour_result[len(candidate_events)] += 1
        if len(candidate_events) == 0:
            print("")
            continue
        print(len(candidate_events))
        centerpoint = json.loads(centerpoint_row[6].replace("'", '"'))
        candidate_event_distances = [haversine(centerpoint['lon'], centerpoint['lat'], float(event['Longitude']), float(event['Latitude'])) for event in candidate_events]
        print(candidate_event_distances)
        candidate_events = [event for event in candidate_events if haversine(centerpoint['lon'], centerpoint['lat'], float(event['Longitude']), float(event['Latitude'])) < distance]
        print(len(candidate_events))
        print()
        if len(candidate_events) == 1:
            print("")
            print(centerpoint_row[4])
            print(candidate_events[0]["date"]) 
            print(candidate_events[0]["tweet"]) 
            print("")

        result[len(candidate_events)] += 1

print(result)
print(same_hour_result)
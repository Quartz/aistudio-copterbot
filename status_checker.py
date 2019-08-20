import requests
import pymysql
import pymysql.cursors
import yaml
from datetime import datetime, timedelta
from os.path import join, dirname, basename, abspath
from os import environ
import json
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

creds = yaml.safe_load(open(join(dirname(__file__), "creds.yml")))
connection = pymysql.connect(host=env('MYSQLHOST'),
                             user=env('MYSQLUSER') or env('MYSQLUSERNAME'),
                             port=env('MYSQLPORT'),
                             password=env('MYSQLPASSWORD'),
                             db=env('MYSQLDATABASE') or "dump1090",
                             charset='utf8mb4',
                             cursorclass=pymysql.cursors.DictCursor)

site_names = {
    1: "John",
    2: "Mike, west",
    3: "Mike, east"
}

with connection.cursor() as cursor:
    # Create a new record
    sql = "SELECT client_id, count(*) cnt from squitters where parsed_time >= '{}' group by client_id;".format((datetime.now() - timedelta(hours=24)).isoformat()[0:19].replace("T", " "))
    cursor.execute(sql)
    results = cursor.fetchall()
    sites = []
    total_messages = 0
    for row in results:
        sites.append(row["client_id"])
        total_messages += int(row["cnt"])

    missing_site_names = []
    for site, site_name in site_names.items():
        if site in sites:
            continue
        missing_site_names.append((site, site_name))

message = "NYPD Copters: {} total messages from *{}*/{} sites ({}), in the past 24 hours. ".format(
    f'{total_messages:,}',
    len(sites),
    len(site_names.keys()),
    ', '.join([str(s) for s in sites]),
    )

if len(missing_site_names) >= 1:
    message += "MISSING: " + (', '.join([f"{site_name} ({site})" for site, site_name in missing_site_names]))

print(message)
resp = requests.post(creds['slack']['webhook'], data=json.dumps( { "text": message }), headers={"Content-Type": "application/json"})

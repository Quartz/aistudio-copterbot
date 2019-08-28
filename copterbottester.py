from nypdcopterbot import *


crs = 2263 # NY State Plane
flightpath = Flightpath.from_json('N918PD-2019-08-27T12_57_48-2019-08-27T13_01_21.flightpath.json')

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

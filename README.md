NYPD Copterbot
==============

Chop chop chop!

What the f*** is going on here?
-------------------------------

It's a common feeling in New York City. _I got woken up at 4:30 in the morning last night by some damn police helicopter circling like five feet above my apartment_, you say. _Do you know what it was?_ your friend asks, even though they know. You don't have any idea.

This bot aims to help solve that problem, at least a little bit, by:

 1. tracking where the NYPD's helicopters are flying -- with ADS-B
 2. figuring out when they're hovering  -- with machine learning
 3. calculating the center point of the circles they make while flying -- with geometry
 4. figuring out what happened at that point around that time -- with machine learning

So far, #1 is solved.

Fun fact!
---------

Etymologically, _helicopter_ comes from _helix_ + _pteron_ meaning, well, "helix" and "wing" (like a _pterodactyl_). But someone reanalyzed it as _heli_ + _copter_ and now we have _copters_! Wow.

I want to do this myself, for my city.
-------------------------

Cool. It's kind of involved but it's totally doable. I believe in you.

1. You need to be able to receive ADSB signals for your area. You need to put a handful of Raspberry Pis with DVB-T receivers in areas with line of sight to most/all of your area. They don't have to all be in the same place. (We have receivers in far northern Manhattan, lower Manhattan and Brooklyn...)
2. Build out a basemap in dump1090-mapper. In New York City, we use parks, airports and rivers/the bay as wayfinding guides. What to use here depends on your city; in Atlanta, I'd use the freeways. Pull requests accepted.
3. Set up one MySQL database for all the receivers to write to.
4. more to come...
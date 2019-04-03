# Spotting circling helicopters, using images as data

When police helicopter circles overhead, I always wonder what's up.

It's a sign, a trigger. The longer it's circling, the more likely I'll check Twitter or a local news site to find out what's going on.

Take that a step further, and we think that sign -- a circling helicopter -- could be a good tip for local reporters that there's a story in the works. Something worth checking out. 

So we wondered: Could we train a computer to spot circling helicopters?

It turns out, we can.

## Getting the data

Nearly all aircraft transmit their identity and location, which helps keep them from running into each other(CK). Those signals are not encrypted and are relatively easy to detect with an antenna, a hobby computer, and a little code.

[Image of a pi setup]

It's thousands of these receivers that power real-time maps like [FlightAware](https://flightaware.com) and [Flightradar24](https://flightradar24.com). Those sites are a great source for flight data, and Flightradar24 is where BuzzFeed got data for its great work [detecting hidden spy planes](https://www.buzzfeednews.com/article/peteraldhous/hidden-spy-planes).

But you can collect your own data, too. With a couple of these receivers, we now track all aircraft flying around New York City -- including NYPD helicopters. Jeremy B. Merrill even set up a nifty bot that posts a message in our Slack every time one of those choppers is aloft.

[Image from slack]

## Detecting circling

Now we want to detect not just _anytime_ a 'copter is in the air, but when one is flying in circles. That's the sign.

So using rows and rows of our flight data, Jeremy has been training a machine learning model to spot moments when the helicopters are hovering or circling. He taught the computer which rows are "yes hovering", which ones are "not hoving" and the had it guess on data it hadn't seen before. After lots of training and tinkering, the computer was right 73% of the time. Which is okay, but not excellent.

Meanwhile I was taking a free online class called [Practical Machine Learning for Coders](https://course.fast.ai/) from Fast.ai, a machine-learning platform I really like that's committed to "making neural nets uncool again" -- essentially democratizing AI.

The first lessons are about images, and we quickly learned how to teach a computer to distinguish between dog and cat breeds(!) or separate teddy bears from black bears and grizzly bears. At one point instructor Jeremy Howard mentioned that computer-mouse movements have been be turned into "data pictures" so that an image algorithm could detect patterns, [such as fraud](https://www.splunk.com/blog/2017/04/18/deep-learning-with-splunk-and-tensorflow-for-security-catching-the-fraudster-in-neural-networks-with-behavioral-biometrics.html).

I thought: Hey, those maps Jeremy Merrill's bot is posting in Slack are basically "data images." **I** can see when a helicopter is circling in them. Could I train a computer to see the same thing?

## Seeing circling

I went to the directory where we store the images and grabbed a bunch of the most recent -- 183 in all. I then sorted them into two folders: `1` for circling, and `0` for not circling. I then pointed the Fast.AI software at those two folders.

[image of 1/0 classification]

Following the same steps in the lesson, in my pajamas while home sick, I quickly got a reliable accuracy of 89% -- which is pretty great. The computer guessed right almost 9 out of 10 times.

Not only that, I could apparently _see_ where the computer got things wrong.

[image of top losses]

And eventually, I could check out new, single images. Here, you can see that the output was "Category 1" -- circling:

[image of new one]

## 


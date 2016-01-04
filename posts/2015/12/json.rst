.. title: Playing with JSON and React
.. slug: json
.. date: 2015-12-28 22:29:46 UTC
.. tags: JavaScript,Weather,React,NWS,Bridgton Academy
.. category:
.. link:
.. description:
.. type: text
.. nocomments: True

Recently I got the school's `weather station online <http://weather.bridgtonacademy.org>`__.

We are using a Davis Vantage Pro2. It is located at the top of Chadborne Hill,
but the classroom is not, requiring two repeaters to make it down the hill. Then
I have a computer running `WeeWX <http://www.weewx.com>`_ to archive the data
and push it to our FTP server every 5 min. This saves me from having to keep
another internet facing machine patched which is awesome.

I started to add a bunch of basic resources, like the national forecast and the
storm total snow images to the sidebar when I discovered that that National
Weather service has a json endpoint for their forecast pages. I haven't found
much documentation of the endpoint other than a
`StackOverflow Post <http://stackoverflow.com/questions/2502340/noaa-web-service-for-current-weather>`_.

Seeing that it was json, got me wondering if it might just be enough to embed
the NWS graphical forecast into the website. Maybe a bit like this:

|Weather.bridgtonacademy.org|

.. TEASER_END

It turns out that the endpoint provides basically all the info you need to
rebuild the core forecast page. So if you start with our
`North Bridgton Forecast <http://forecast.weather.gov/MapClick.php?lat=44.0986&lon=-70.6991>`_
and add ```&FcstType_json`` onto the end you will get a nicely
`nicely structured JSON <http://forecast.weather.gov/MapClick.php?lat=44.0986&lon=-70.6991&FcstType=json>`_.

I've recently been trying to work on my JavaScript knowledge, so this seemed
like a good time to try to put them to work. I knew that
`React <https://facebook.github.io/react/>`_ was pretty lightweight and wouldn't
require many changes to the existing code that WeeWX was already processing so
I started building a set of
`React components for NWS JSON <https://github.com/abkfenris/nws_json_react>`_.
Right now they are pretty basic and focused on that single graphical display.

This also made me try to understand the JavaScript build system. I'm going to be
glad that I will only be needing to teach my students about Pip and Conda in a
few weeks.

I was able to get a basic example running on my machine, and got it to the place
where all someone needs is a div and a small script block with their lat-long
to pull a forecast.

.. code-block:: html

  <div id="forecast">I'm going to be turned into the forecast</div>

.. code-block:: js

  React.render(
    <Forecast lat="44.098601844800385" lon="-70.69908771582459" pollInterval={200000}/>,
    document.getElementById('forecast')
  )

Now due to that troublesome thing called CORS and NWS's headers you can't just
load it from another website directly, but if you pass ``&callback=nwsresponse``
the NWS servers will wrap it correctly in ``nwsresponse(json)`` as
`JSONP <https://en.wikipedia.org/wiki/JSONP>`_.

Thankfully I'm not the first to encounter this issue as
`jQuery.ajax <http://api.jquery.com/jquery.ajax/>`_
supports callbacks natively, though the documentation is very sterile. It's
probably pretty good for someone who is looking for specifics, but I was more
looking for the `tldr <http://tldr-pages.github.io>`_ version of things. I had a
few issues as jquery was actually trying to be too smart and append it's own
callback after detecting that I was requesting a callback. Now it takes care of
that, and all that is left is styling.

To make the forecast show up in a similar side scrolling container, you just
need a bit of css in the right place (which caused a detour through
`SASS <http://sass-lang.com>`_) as the theme I had started with was using it.

.. code-block:: css

  ul.forecastGraphicalList {
    white-space: nowrap;
    overflow-x: auto;
    list-style-type: none;

  }
  li.forecast-period {
    width: 124px;
    display: inline-block;
    vertical-align: top;
    white-space: normal;
  }

|Weather.bridgtonacademy.org|

Now it isn't just an idea, but it's loaded client side!

I also found `Iowa State's APIs <http://mesonet.agron.iastate.edu/json/>`_ while
poking around for a CORS compatable NWS endpoint, but didn't explore them too
much as I was looking for the normal forcast page information.

Also I rebuilt my site using `Nikola <https://getnikola.com>`_ which should
become really useful with code-heavy posts that will probably happen more often
with the Intro to Programming course that I am going to be teaching. I've got
some more sprucing up to do with both the theme and the content, but this is a
nice start.

.. |Weather.bridgtonacademy.org| image:: /wp-content/uploads/2015/12/weather.png
   :target: /wp-content/uploads/2015/12/weather.png

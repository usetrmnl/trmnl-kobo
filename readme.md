# Turn Your Kobo into a TRMNL client
This repository contains the implementation and a guide to make your kobo acts as a TRMNL client on demand.

**This is a work in progress**

" *TRMNL is an e-ink display that connects with popular products and renders their most useful information. We believe this black & white, focused, hands-off approach is the best way to stay informed without getting distracted [TRMNL website](https://usetrmnl.com/).* "

< INSERT PICTURE HERE >

## Sumary
This will add a menu entry to start TRMNL app to your kobo. 
- The TRMNL app will periodically request a dashboard screen to be displayed on the Kobo screen.
- The refresh rate is given by the server
- In between request the Kobo will be put to sleep, and will wake up for the next update.
- When awake the charging led of the Kobo is lit to let you know that the wifi is being turned on and a request being sent.

This repository structure is:
- ./src/ : contains the TRMNL client implementation (mainly scripts, heavily inspired by koreader < attribute to author >)
- ./doc/distrib : contains the prerequisites and sources, for references and archival (some where found on the internet wayback machine) 
  - nickelmenu: adds a new tab to your kobo that allows you to start external app < ref author >
  - kobostuff: adds tools to your kobo < ref author >
  - rtcwake: patched busybox binary to allow to set up rtc wake up alarm on kobo < ref author / wayback machine>

## Prerequisites

- Kobo device connected to wifi
- If you want to benefit to the awesome TRMNL ecosystem you will need a TRMNL API key (physical device or [BYOD license](https://shop.usetrmnl.com/products/byod)), or point to your own TRMNL server [BYOS](https://docs.usetrmnl.com/go/diy/byos)

## Installation
Here are the steps to get the TRMNL app working on your Kobo
- Install NickelMenu < attribute to author > on your Kobo
- Install Kobostuff  < attribute to author > on your Kobo
- Copy TRMNL folder content to the Kobo in **.adds** folder (might be hidden < DOCUMENT >)
- Edit **trmnl.sh** located in **.adds/TRMNL** to setup:
  - Device Id/Mac address in **trmnl_id** variable
  - Device token/API key in **trmnl_token** variable
- Copy the file TRMNL.ini to **.adds/nm** folder (to create a menu entry) 
- TRMNL app can be started using NickelMenu

## Digging into sources
< TODO explain script loop and configuration >

These checks execute the production audio startup coordinator, packet lifetime
budget, resolution-dependent frame capacity and user resumption gate. The normal
and Thread Sanitizer commands are in the metadata CI job. They inject startup
errors and concurrent packet owners without starting audio hardware or decoding
media. The full Apple SDK build additionally checks the actual AudioEngine,
MEPlayerItem and iOS session wiring. Media Services Reset and physical output
device recovery still require device verification.

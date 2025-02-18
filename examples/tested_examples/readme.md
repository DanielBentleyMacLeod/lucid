## Tested lucid examples

This directory contains example programs whose execution has been tested. In other words, these are applications that you should be able to run completely on a real switch. 

#### Contents

- ``src/`` -- the lucid applications

- ``tests/`` -- test cases, use with scripts in ``<git root>/test``

- ``ip_harness.p4`` -- a simple IP harness. 

- ``ip_harness_triggers.json`` -- entry event triggers for the IP harness.

- ``makefile`` -- compile, assemble, and test all the applications in this directory. 
    - ``make assemble_{appname}`` compile ``src/appname.dpt`` from Lucid to P4, in ``builds/{appname}``
    - ``make assemble_{appname}`` compile the P4 in ``builds/{appname}`` into a tofino binary
    - ``make test_{appname}`` test the compiled P4 in ``builds/{appname}`` on the Tofino asic model, using the test case ``tests/{appname}.json``.

#### Applications 

- **reflector** -- sends an ip packet out of the same port it came in on. 

- **control_reflector** -- generates a control event from an ip packet. When processing the control event, generates an exit event that sends the packet out of the same port it arrived on. 

- **simple_cuckoo_firewall** -- a stateful firewall that uses a cuckoo hash table to remember connections from trusted hosts. Insert operations, for the hash table, may occur over multiple events that move items around in memory to mitigate collisions.

#### Harness

All programs use a common P4 harness, ``ip_harness.p4`` and its configuration file, ``ip_harness_triggers.json``. This harness parses ethernet/ip packets and can be configured, using the json, to generate events based on any parsed header fields, and handle exit events by changing parsed field values. 

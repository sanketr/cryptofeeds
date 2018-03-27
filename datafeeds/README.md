# Crypto Data Feed

### How to Compile

```
stack build
```

This will generate two executables, one to subscribe to GDAX data feed (`feedlogger`), and another to process the logs saved down by data feeds (`proclog`). Run `find ./ -name <executable name>` to locate the executables if you are not sure about the paths.

### Capturing Exchange Messages
Run `feedlogger` to capture and save down crypto data under logs folder. This executable will make sure of the following:

* Rotate logs by starting a new date at GMT midnight rollover (according to system clock)
* Make sure that any new log doesn't overwrite an existing log. This is ensured by incrementing the log number in case a log already exists for the current GMT date
* The logging is done in append-only mode. Each new message from the exchange is immediately saved to disk without buffer, after compression. In tests, a ~300k uncompressed log is about ~50k due to compression of each message

### Replaying Exchange Messages

Run `proclog` to replay exchange messages. It takes input from standard input, and publishes output (in `json` format) to standard output. It will replay only normal binary log, not error log (which is already in `json` format). An example of how to replay a log:

```
cat logs/gdax/2018.03.20/1/normal1.log | <path to parent directory where proclog is>/proclog
```

If the log is well-formed, you should see output like following on standard output (which in turn can be piped to another program):

```
{"type":"l2update","product_id":"ETH-USD","changes":[["buy","519.52000000","6.25"]]}{"type":"l2update","product_id":"BTC-USD","changes":[["sell","8424.98000000","0"]]}{"type":"l2update","product_id":"BTC-USD","changes":[["sell","8481.50000000","0"]]}{"type":"l2update","product_id":"BTC-USD","changes":[["buy","8399.58000000","0"]]}
```

# Riak-Ruby-Ledger

An alternative to Riak Counters with idempotent writes within a client defined window.

# Summary

### Quick Links

Below are a few documents that are relevant to this gem, **please read before considering using this gem for anything important**.

##### Riak Ruby Ledger Docs

Document Link | Description
--- | ---
[[docs/riak_counter_drift.md]](https://github.com/drewkerrigan/riak-ruby-ledger/blob/master/docs/riak_counter_drift.md) | Why Riak Counters may or may not work for your use case (Counter Drift).
[[docs/implementation.md]](https://github.com/drewkerrigan/riak-ruby-ledger/blob/master/docs/implementation.md) | Implementation details about this gem as well as some of the reasoning behind the approach.
[[docs/usage.md]](https://github.com/drewkerrigan/riak-ruby-ledger/blob/master/docs/usage.md) | Suggested usage of this gem from your application, and implications of changing various settings.
[[docs/release_notes.md](https://github.com/drewkerrigan/riak-ruby-ledger/blob/master/docs/release_notes.md)] | Information about what changed in each version

### Counter Drift

**Why shouldn't I use Riak Counters?**

CRDT PNCounters (two plain GCounters) such as Riak Counters are non-idempotent and store nothing about a counter transaction other than the final value. This means that if an increment operation fails in any number of ways (500 response from server, process that made the call dies, network connection is interrupted, operation times out, etc), your application now has no idea whether or not the increment actually happened.

**What is Counter Drift?**

In the above situation of a failed increment operation, your application has two choices:

1. Retry the operation
	a. This could result in the operation occuring twice causing what is called **positive counter drift**
2. Don't retry the operation
	b. This could result in the operation never occuring at all causing **negative counter drift**

As such it doesn't make sense to use plain GCounters or PNCounters to store any counter that needs to be accurate.

***More information about Riak Counters and Drift***: [[docs/riak_counter_drift.md]](https://github.com/drewkerrigan/riak-ruby-ledger/blob/master/docs/riak_counter_drift.md)

### Implementation

The data type implemented is a PNCounter CRDT with an ordered array of transactions for each GCounter actor. Transaction ids are stored with the GCounter, so operations against this counter are idempotent while the transaction remains in any actor's array.

**High Level API**

Function | Description
--- | ---
`Riak::Ledger.new` | Creates a new Ledger instance
`Riak::Ledger.find!` | Finds an existing Ledger in Riak, merges it locally, and then writes the merged value back to Riak
`#credit!`, `#debit!`, `#update!` | Reads the existing state of the ledger from Riak, merges it locally, and adds a new `transaction` and positive or negative `value`

**Ledger Options**

Name | Description
--- | ---
`:retry_count`[Integer] | When a write to Riak is a "maybe" (500, timeout, or any other error condition), resubmit the request `:retry_count` number of times, and return false if it is still unsuccessful
`:history_length`[Integer] | Keep up to `:history_length` number of transactions in each actor's section of the underlying GCounter. When the (`:history_length` + 1)th transaction is written then merged, add the oldest transaction's value to the actor's total

***More information about the implementation and how edge cases can be avoided***: [[docs/implementation.md]](https://github.com/drewkerrigan/riak-ruby-ledger/blob/master/docs/implementation.md)

### Suggested Usage and Configuration

Depending on your use case, you may want to tweak the configuration options `:history_length` and `:retry_count`.

The default `:history_length` is 10. This means that if a transaction fails, but your application is unable to determine whether or not the counter was actually incremented, you have a buffer space or window of 9 additional transactions on that counter before you can no longer retry the original failed transaction without assuming counter drift is happening.

The default `:retry_count` is also 10. This means that if a transaction fails, the actor that attempted the transaction will continue trying 9 more times. If the request to change the counter still fails after the 10th try, the operation will return `false` for failure. At this point your application can attempt to try the transaction again, or return a failure to the user with a note that the transaction will be retried in the future.

An example of a failure might look like the following:

1. transaction1 fails with actor1, and because of the nature of the failure, your application is unsure whether or not the counter was actually incremented.
	a. If your `:retry_count` is low, you can quickly determine in your application that something went wrong, and inform the user that the transaction was unsuccessful for now, but will be attempted later
	b. If your `:retry_count` is high, the user will be kept waiting longer, but the odds of the transaction eventually working are higher
2. If after the initial retries, the transaction was still a failure, your application must decide what to do next
	a. If your `:history_length` is low, your options are limited. You must continue to retry that same failed transaction for that user (using any available actor) until it is successful. If you allow additional transactions to take place on the same counter before retrying, you run a high risk of counter drift.
	b. If your `:history_length` is medium-high, then you have an allowance of (`:history_length` - 1) additional transactions for that counter before you run the risk of counter drift.

**Note**

This gem cannot guarentee transaction idempotence of a counter for greater than `:history_length` number of transactions.

***More information about configuration and implications of changing various settings***: [[docs/usage.md]](https://github.com/drewkerrigan/riak-ruby-ledger/blob/master/docs/usage.md)

##### Additional Reading

Document Link | Description
--- | ---
[[http://hal.upmc.fr/docs/00/55/55/88/PDF/techreport.pdf](http://hal.upmc.fr/docs/00/55/55/88/PDF/techreport.pdf)] | CRDT paper from Shapiro et al. at INRIA
[[http://basho.com/counters-in-riak-1-4/](http://basho.com/counters-in-riak-1-4/)] | Riak Counters
[[github.com/basho/riak_dt](https://github.com/basho/riak_dt)] | Other Riak Data Types

# Installation

Add this line to your application's Gemfile:

    gem 'riak-ruby-ledger'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install riak-ruby-ledger

# Usage

### Initialize

```
require 'riak' # riak-client gem
require 'ledger' # riak-ruby-ledger gem

# Name each of your threads
Thread.current["name"] = "ACTOR1"

# Create a Riak::Client instance
client = Riak::Client.new pb_port: 8087

# Default option values
options = {
	:actor => Thread.current["name"], # Actor ID, one per thread or serialized writer
	:history_length => 10, # Number of transactions to store per actor per type (credit or debit)
	:retry_count => 10 # Number of times to retry Riak requests if they fail
}

# Create the ledger object
#                         Riak::Bucket        Key        Hash
ledger = Riak::Ledger.new(client["ledgers"], "player_1", options)
```

### Credit and debit

```
ledger.credit!("transaction1", 50)
ledger.value # 50
ledger.debit!("transaction2", 10)
ledger.value # 40

ledger.debit!("transaction2", 10)
ledger.value # 40
```

### Finding an exisitng Ledger

```
ledger = Riak::Ledger.find!(client["ledgers"], "player_1", options)
ledger.value # 40
```

### Request success

If a call to `#debit!` or `#credit!` does not return false, then the transaction can be considered saved, because it would have retried otherwise. Still, for debugging, testing, or external failure policies, `#has_transaction?` is also exposed

```
ledger.has_transaction? "transaction2" # true
ledger.has_transaction? "transaction1" # true
```

### Merging after history_length is reached

For this example, the `:history_length` is lowered to 3 so it gets reached faster.

```
options = {:history_length => 3}
ledger = Riak::Ledger.new(client["ledgers"], "player_2", options)

ledger.credit!("txn1", 10)
ledger.credit!("txn2", 10)
ledger.credit!("txn3", 10)
ledger.credit!("txn4", 10)
ledger.credit!("txn5", 10)
ledger.credit!("txn6", 10)

ledger.value #60

ledger.has_transaction? "txn1" #false
ledger.has_transaction? "txn2" #false
ledger.has_transaction? "txn3" #true

# txn3 is still in the history because the most previous write does not trigger a merge of the actor's total
# Performing a find! will trigger the merge however
ledger = Riak::Ledger.find!(client["ledgers"], "player_2", options)

ledger.has_transaction? "txn3" #false
ledger.has_transaction? "txn4" #true
ledger.has_transaction? "txn5" #true
ledger.has_transaction? "txn6" #true
```

### Deleting a ledger

```
ledger.delete()
```

# Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
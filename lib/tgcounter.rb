require 'set'

module Riak::CRDT
  class TGCounter
    attr_accessor :counts

    def initialize()
      self.counts = TransactionList.new()
    end

    def to_json
      {
          type: 'TGCounter',
          c: counts.transactions
      }.to_json
    end

    def self.from_json(json)
      h = JSON.parse json
      raise ArgumentError.new 'unexpected type field in JSON' unless h['type'] == 'TGCounter'

      gc = new
      gc.counts = h['c']
      return gc
    end

    def increment(actor, transaction, value)
      counts += Transaction.new(actor, transaction, value)
    end

    def has_transaction?(transaction)
      counts.each do |actor, txns|
        txns.keys.member?(transaction)
      end
    end

    def value()
      counts.values.inject(0, &:+)
    end

    def merge(other)
      new_keys = Set.new
      new_keys.merge counts.keys
      new_keys.merge other.counts.keys

      new_keys.each do |k|
        counts[k] = [counts[k], other.counts[k]].max
      end
    end

    def tag
      radix = 36
      [
          object_id.to_s(radix),
          Process.uid.to_s(radix),
          Process.gid.to_s(radix),
          Process.pid.to_s(radix),
          `hostname`.strip
      ].join
    end






















    # Cannot modify other actors' sets because of possible simultaneous merges
    def merge(actor, other)
      merge_actor(actor, other) if actor

      other.counts.each do |act, v|
        v.each do |t, num|
          counts[act] = Hash.new() unless counts[act]
          counts[act][t] = 0 unless counts[act][t]
          other.counts[act][t] = 0 unless other.counts[act][t]

          counts[act][t] = [counts[act][t], num].max
        end
      end
    end

    def merge_actor(actor, other)
      new_keys = Set.new

      counts[actor] = Hash.new unless counts[actor]
      other.counts[actor] = Hash.new unless other.counts[actor]

      new_keys.merge counts[actor].keys
      new_keys.merge other.counts[actor].keys if other.counts[actor]

      new_keys.each do |k|
        counts[actor][k] = 0 unless counts[actor][k]
        other.counts[actor][k] = 0 unless other.counts[actor][k]

        counts[actor][k] = [counts[actor][k], other.counts[actor][k]].max
      end

      actor_total = counts[actor].values.inject(0, &:+)

      counts[actor] = Hash.new()
      counts[actor]["total"] = actor_total
    end
  end
end

module Riak::CRDT
  class Transaction
    attr_accessor :id, :value

    def initialize(id, value)
      self.id = id
      self.value = value
    end
  end
end

module Riak::CRDT
  class TransactionList
    attr_accessor :transactions

    def initialize()
      self.transactions = Hash.new()
    end
  end
end
class Reactor::Event
  include Sidekiq::Worker

  sidekiq_options queue: ENV['REACTOR_QUEUE'] || "default"

  CONSOLE_CONFIRMATION_MESSAGE = <<-eos
    It looks like you are on a production console. Only fire an event if you intend to trigger 
    all of its subscribers. In order to proceed, you must pass `srsly: true` in the event data. To
    configure Reactor to ignore this validation, set `ENV['REACTOR_CONSOLE_ENABLED']` to a value.
  eos

  attr_accessor :__data__

  def initialize(data = {})
    self.__data__ = {}.with_indifferent_access
    data.each do |key, value|
      value = value.encode('UTF-8', invalid: :replace, undef: :replace, replace: '') if value.is_a?(String)
      self.send("#{key}=", value)
    end
  end

  def perform(name, data)
    data = data.with_indifferent_access

    if data['actor_type']
      actor = data["actor_type"].constantize.unscoped.find(data["actor_id"])
      publishable_event = actor.class.events[name.to_sym]
      ifarg = publishable_event[:if] if publishable_event
    end

    need_to_fire =  case ifarg
                    when Proc
                      actor.instance_exec(&ifarg)
                    when Symbol
                      actor.send(ifarg)
                    when NilClass
                      true
                    end

    if need_to_fire
      data.merge!(fired_at: Time.current.to_s, name: name)
      fire_block_subscribers(data.to_hash, name)
    end
  end

  def method_missing(method, *args)
    if method.to_s.include?('=')
      try_setter(method, *args)
    else
      try_getter(method)
    end
  end

  def to_s
    name
  end

  class << self
    def perform(name, data)
      new.perform(name, data)
    end

    def publish(name, data = {})
      if defined?(Rails::Console) && ENV['RACK_ENV'] == 'production' && data[:srsly].blank? &&
         !ENV['REACTOR_CONSOLE_ENABLED']
        raise ArgumentError.new(CONSOLE_CONFIRMATION_MESSAGE)
      end

      message = new(data.merge(event: name, uuid: SecureRandom.uuid))
      Reactor.validator.call(message)
      message_data = message.__data__.to_hash
      if message.at
        event_queue.perform_at(message.at, name, message_data)
      else
        event_queue.perform_async(name, message_data)
      end
    end

    def reschedule(name, data = {})
      scheduled_jobs = Sidekiq::ScheduledSet.new
      # Note that scheduled_jobs#fetch returns only jobs matching the data[:was]
      # timestamp - down to fractions of a second
      job = scheduled_jobs.fetch(data[:was].to_f).detect do |job|
        next if job['class'] != self.name.to_s

        same_event_name  = job['args'].first == name.to_s

        if data[:actor]
          same_actor =  job['args'].second['actor_type']  == data[:actor].class.name &&
                        job['args'].second['actor_id']    == data[:actor].id

          same_event_name && same_actor
        else
          same_event_name
        end
      end

      job.delete if job

      publish(name, data.except([:was, :if])) if data[:at].try(:future?)
    end

    private

    def event_queue
      queue_override = ENV['REACTOR_QUEUE']
      queue_override ||= ::Reactor.default_queue
      queue_override.present? ? set(queue: queue_override) : self
    end
  end

  private

  def try_setter(method, object, *args)
    if object.is_a? ActiveRecord::Base
      send("#{method}_id", object.id)
      send("#{method}_type", object.class.to_s)
    else
      __data__[method.to_s.gsub('=','')] = object
    end
  end

  def try_getter(method)
    if polymorphic_association? method
      initialize_polymorphic_association method
    elsif __data__.has_key?(method)
      __data__[method]
    end
  end

  def polymorphic_association?(method)
    __data__.has_key?("#{method}_type")
  end

  def initialize_polymorphic_association(method)
    __data__["#{method}_type"].constantize.find(__data__["#{method}_id"])
  end

  def fire_block_subscribers(data, name)
    ((Reactor::SUBSCRIBERS[name.to_s] || []) | (Reactor::SUBSCRIBERS['*'] || [])).each do |s|
      s.perform_where_needed(data)
    end
  end
end

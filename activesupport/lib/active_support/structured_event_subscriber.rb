# frozen_string_literal: true

require "active_support/core_ext/class/attribute"
require "active_support/subscriber"

module ActiveSupport
  # = Active Support Structured Event \Subscriber
  #
  # +ActiveSupport::StructuredEventSubscriber+ consumes ActiveSupport::Notifications
  # in order to emit structured events via +Rails.event+.
  #
  # An example would be the Action Controller structured event subscriber, responsible for
  # emitting request processing events:
  #
  #   module ActionController
  #     class StructuredEventSubscriber < ActiveSupport::StructuredEventSubscriber
  #       attach_to :action_controller
  #
  #       def start_processing(event)
  #         emit_event("controller.request_started",
  #           controller: event.payload[:controller],
  #           action: event.payload[:action],
  #           format: event.payload[:format]
  #         )
  #       end
  #     end
  #   end
  #
  # After configured, whenever a <tt>"start_processing.action_controller"</tt> notification is published,
  # it will properly dispatch the event (+ActiveSupport::Notifications::Event+) to the +start_processing+ method.
  # The subscriber can then emit a structured event via the +emit_event+ method.
  class StructuredEventSubscriber < Subscriber
    class_attribute :debug_methods, instance_accessor: false, default: [] # :nodoc:

    @@attached_structured_classes = [] # :nodoc:
    @@debug_notifications_registry = [] # :nodoc:

    class << self
      def attach_to(...) # :nodoc:
        result = super
        set_silenced_events
        register_attached_structured_class
        result
      end

      def detach_from(namespace, notifier = ActiveSupport::Notifications) # :nodoc:
        result = super
        unregister_attached_structured_class(notifier)
        result
      end

      # Registers an +ActiveSupport::Notifications+ subscription that should
      # only stay attached while the event reporter would actually consume
      # debug events (i.e. it has at least one subscriber and is in debug mode).
      # Use this for start/finish listeners that report structured debug events,
      # so that non-debug apps don't pay for instrumentation whose output would
      # be discarded.
      def attach_debug_notifications(pattern, listener, notifier = ActiveSupport::Notifications) # :nodoc:
        entry = { pattern: pattern, listener: listener, notifier: notifier, klass: self, handle: nil }
        @@debug_notifications_registry << entry
        if debug_events_active?
          entry[:handle] = notifier.subscribe(pattern, listener)
        end
      end

      # Re-evaluate whether debug-only structured subscribers should be
      # attached. Invoked by +ActiveSupport::EventReporter+ whenever the
      # conditions that determine +debug_events_active?+ can have changed
      # (a subscriber was added or removed, or +debug_mode=+ was called).
      def sync_debug_events # :nodoc:
        active = debug_events_active?

        @@attached_structured_classes.each do |klass|
          klass.__send__(:sync_debug_event_subscriptions, active)
        end

        @@debug_notifications_registry.each do |entry|
          if active && entry[:handle].nil?
            entry[:handle] = entry[:notifier].subscribe(entry[:pattern], entry[:listener])
          elsif !active && entry[:handle]
            entry[:notifier].unsubscribe(entry[:handle])
            entry[:handle] = nil
          end
        end
      end

      def debug_events_active? # :nodoc:
        ActiveSupport.event_reporter.debug_events_available?
      end

      private
        def set_silenced_events
          if subscriber
            subscriber.silenced_events = debug_methods.to_h { |method| ["#{method}.#{namespace}", true] }
          end
        end

        def debug_only(method)
          self.debug_methods += [method]
          set_silenced_events

          # If this class is already attached and debug events aren't currently
          # active, drop the just-added subscription so we stop instrumenting.
          if @subscriber && @notifier && !debug_events_active?
            remove_event_subscriber(method)
          end
        end

        def add_event_subscriber(event)
          if debug_methods.include?(event.to_sym) && !debug_events_active?
            return
          end
          super
        end

        def register_attached_structured_class
          @@attached_structured_classes << self unless @@attached_structured_classes.include?(self)
        end

        def unregister_attached_structured_class(notifier)
          @@attached_structured_classes.delete(self) unless find_attached_subscriber

          @@debug_notifications_registry.delete_if do |entry|
            if entry[:klass] == self
              if entry[:handle]
                entry[:notifier].unsubscribe(entry[:handle])
              end
              true
            end
          end
        end

        def sync_debug_event_subscriptions(active)
          debug_methods.each do |method|
            if active
              add_event_subscriber(method)
            else
              remove_event_subscriber(method)
            end
          end
        end
    end

    def initialize
      super
      @silenced_events = {}
    end

    def silenced?(event)
      ActiveSupport.event_reporter.subscribers.none? || (@silenced_events.key?(event) && !ActiveSupport.event_reporter.debug_mode?)
    end

    attr_writer :silenced_events # :nodoc:

    # Emit a structured event via Rails.event.notify.
    #
    # ==== Arguments
    #
    # * +name+ - The event name as a string or symbol
    # * +payload+ - The event payload as a hash or object
    # * +caller_depth+ - Stack depth for source location (default: 1)
    # * +kwargs+ - Additional payload data merged with the payload hash
    def emit_event(name, payload = nil, caller_depth: 1, **kwargs)
      ActiveSupport.event_reporter.notify(name, payload, caller_depth: caller_depth + 1, filter_payload: false, **kwargs)
    rescue => e
      handle_event_error(name, e)
    end

    # Like +emit_event+, but only emits when the event reporter is in debug mode
    def emit_debug_event(name, payload = nil, caller_depth: 1, **kwargs)
      ActiveSupport.event_reporter.debug(name, payload, caller_depth: caller_depth + 1, filter_payload: false, **kwargs)
    rescue => e
      handle_event_error(name, e)
    end

    def call(event)
      super
    rescue => e
      handle_event_error(event.name, e)
    end

    private
      def handle_event_error(name, error)
        ActiveSupport.error_reporter.report(error, source: name)
      end
  end
end

import Foundation
import Combine

struct DispatchTimerConfiguration {
  // 1 You want your timer to be able to fire on the specified queue, but you also want to make the queue optional if you don’t care. In this case, the timer will fire on a queue of its choice.
  let queue: DispatchQueue?
  // 2 The interval at which the timer will fire, starting from the subscription time.
  let interval: DispatchTimeInterval
  // 3 The leeway, which is the maximum amount of time after the deadline that the system may delay the delivery of the timer event.
  let leeway: DispatchTimeInterval
  // 4 The number of timer events you want to receive. Since you’re making your own timer, make it flexible and able to deliver a limited number of events before completing!
  let times: Subscribers.Demand
}

//####### Custom Publisher#######
extension Publishers {
  struct DispatchTimer: Publisher {
    // 5 Your timer emits the current time as a DispatchTime value. Of course, it never fails, so the publisher’s Failure type is Never.
    typealias Output = DispatchTime
    typealias Failure = Never
    
    // 6 Keeps a copy of the given configuration. You don’t use it right now, but you’ll need it when you receive a subscriber.
    let configuration: DispatchTimerConfiguration
    
    init(configuration: DispatchTimerConfiguration) {
      self.configuration = configuration
    }
    
    // 7 The function is a generic one; it needs a compile-time specialization to match the subscriber type.
    func receive<S: Subscriber>(subscriber: S) where Failure == S.Failure, Output == S.Input {
      
      // 8 The bulk of the action will happen inside the DispatchTimerSubscription that you’re going to define in a short while.
      let subscription = DispatchTimerSubscription(subscriber: subscriber, configuration: configuration)
      // 9 As you learned in Chapter 2, “Publishers & Subscribers,” a subscriber receives a Subscription, which it can then send requests for values to.
      subscriber.receive(subscription: subscription)
    }
  }
}

//############# Subscription #############
private final class DispatchTimerSubscription<S: Subscriber>: Subscription where S.Input == DispatchTime {
    
    // 10 The configuration that the subscriber passed.
    let configuration: DispatchTimerConfiguration
    
    // 11 The maximum number of times the timer will fire, which you copied from the configuration. You’ll use it as a counter that you decrement every time you send a value.
    var times: Subscribers.Demand
    
    // 12 The current demand from the subscriber — you decrement it every time you send a value.
    var requested: Subscribers.Demand = .none
    
    // 13 The internal DispatchSourceTimer that will generate the timer events.
    var source: DispatchSourceTimer? = nil
    
    // 14 The subscriber. This makes it clear that the subscription is responsible for retaining the subscriber for as long as it doesn’t complete, fail or cancel.
    var subscriber: S?
    
    init(subscriber: S, configuration: DispatchTimerConfiguration) {
      self.configuration = configuration
      self.subscriber = subscriber
      self.times = configuration.times
    }
    
    //This method must be implemented according to the Subscription Protocol
    func cancel() {
      source = nil
      subscriber = nil
    }
    
    // 15 “Demands are cumulative: They add up to form a total number of values that the subscriber requested.
    func request(_ demand: Subscribers.Demand) {
      // 16 “Your first test is to verify whether you’ve already sent enough values to the subscriber, as specified in the configuration. That is, if you’ve sent the maximum number of expected values, independent of the demands your publisher received.
      guard times > .none else {
        // 17 If this is the case, you can notify the subscriber that the publisher has finished sending values.
        subscriber?.receive(completion: .finished)
        return
      }
        
      // 18 “Increment the total number of requested values by adding the new demand.
      requested += demand

      // 19 “Check whether the timer already exists. If not, and if requested values exist, then it’s time to start it.
      if source == nil, requested > .none {
        // 20 “Create the DispatchSourceTimer from the optional requested queue.
        let source = DispatchSource.makeTimerSource(queue: configuration.queue)
        // 21 “Schedule the timer to fire after every configuration.interval seconds.
        source.schedule(deadline: .now() + configuration.interval,
                        repeating: configuration.interval,
                        leeway: configuration.leeway)
        // 22 Set the event handler for your timer. This is a simple closure the timer calls every time it fires. Make sure to keep a weak reference to self or the subscription will never deallocate.
        source.setEventHandler { [weak self] in
            // 23 Verify that there are currently requested values — the publisher could be paused with no current demand, as you’ll see later in this chapter when you learn about backpressure.
            guard let self = self,
                self.requested > .none else { return }
            
            // 24 Decrement both counters now that you’re going to emit a value.
            self.requested -= .max(1)
            self.times -= .max(1)
            // 25 Send a value to the subscriber
            _ = self.subscriber?.receive(.now())
            // 26 If the total number of values to send meets the maximum that the configuration specifies, you can deem the publisher finished and emit a completion event!
            if self.times == .none {
                self.subscriber?.receive(completion: .finished)
            }
        }
        //27 Store and refference your soruce timer and activate it.
        self.source = source
        source.activate()
      }
    }
    
}

//Define an operator to easily chain this publisher
extension Publishers {
  static func timer(queue: DispatchQueue? = nil,
                    interval: DispatchTimeInterval,
                    leeway: DispatchTimeInterval = .nanoseconds(0),
                    times: Subscribers.Demand = .unlimited)
                    -> Publishers.DispatchTimer {
    return Publishers.DispatchTimer(
      configuration: .init(queue: queue,
                           interval: interval,
                           leeway: leeway,
                           times: times)
                      )
  }
}

//Test your timer:
// 27 it prints the time since it started logging
var logger = TimeLogger(sinceOrigin: true)
// 28 Your itmer will fire exactly 6 times, once every second
let publisher = Publishers.timer(interval: .seconds(1),
                                 times: .max(6))
// 29 “Log each value you receive through your TimeLogger
let subscription = publisher.sink { time in
  print("Timer emits: \(time)", to: &logger)
}

//Test cancelling your timer:
DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
  subscription.cancel()
}

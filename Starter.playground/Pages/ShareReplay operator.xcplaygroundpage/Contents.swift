import Foundation
import Combine

//The following custom operator basically replays a network call

// 1 You use a generic class, not a struct, to implement the subscription: Both the Publisher and the Subscriber need to access and mutate the subscription.
fileprivate final class ShareReplaySubscription<Output, Failure: Error>: Subscription {
    // 2 The replay buffer’s maximum capacity will be a constant that you set during initialization.
    let capacity: Int
    // 3 Keeps a reference to the subscriber for the duration of the subscription. Using the type-erased AnySubscriber saves you from fighting the type system. :]
    var subscriber: AnySubscriber<Output,Failure>? = nil
    // 4 Tracks the accumulated demands the publisher receives from the subscriber so that you can deliver exactly the requested number of values.
    var demand: Subscribers.Demand = .none
    // 5 “Stores pending values in a buffer until they are either delivered to the subscriber or thrown away.”
    var buffer: [Output]
    // 6 “This keeps the potential completion event around, so that it’s ready to deliver to new subscribers as soon as they begin requesting values.
    var completion: Subscribers.Completion<Failure>? = nil
    
    init<S>(subscriber: S,
            replay: [Output],
            capacity: Int,
            completion: Subscribers.Completion<Failure>?)
        where S: Subscriber,
        Failure == S.Failure,
        Output == S.Input {
            // 7
            self.subscriber = AnySubscriber(subscriber)
            // 8
            self.buffer = replay
            self.capacity = capacity
            self.completion = completion
    }
    
    private func complete(with completion: Subscribers.Completion<Failure>) {
        // 9 Keeps the subscriber around for the duration of the method, but sets it to nil in the class. This defensive action ensures any call the subscriber may wrongly issue upon completion will be ignored.
        guard let subscriber = subscriber else { return }
        self.subscriber = nil
        // 10 Makes sure that completion is sent only once by also setting it to nil, then empties the buffer.
        self.completion = nil
        self.buffer.removeAll()
        // 11 “Relays the completion event to the subscriber
        subscriber.receive(completion: completion)
    }
    
    private func emitAsNeeded() {
        guard let subscriber = subscriber else { return }
        // 12 “Emit values only if it has some in the buffer and there’s an outstanding demand.
        while self.demand > .none && !buffer.isEmpty {
            // 13“Decrement the outstanding demand by one.”
            self.demand -= .max(1)
            // 14 Send the first outstanding value to the subscriber and receive a new demand in return.
            let nextDemand = subscriber.receive(buffer.removeFirst())
            // 15 Add that new demand to the outstanding total demand, but only if it’s not .none. Otherwise, you’ll get a crash, because Combine doesn’t treat Subscribers.Demand.none as zero and adding or subtracting .none will trigger an exception.
            if nextDemand != .none {
                self.demand += nextDemand
            }
        }
        // 16 If a completion event is pending, send it now.
        if let completion = completion {
            complete(with: completion)
        }
    }
    
    func request(_ demand: Subscribers.Demand) {
        if demand != .none {
            self.demand += demand
        }
        emitAsNeeded()//“calling emitAsNeeded() even if the demand is .none guarantees that you properly relay a completion event that has already occurred.
    }
    
    // Cancel your subscription:
    func cancel() {
        complete(with: .finished)
    }
    
    func receive(_ input: Output) {
        guard subscriber != nil else { return }
        // 17 add the value to the buffer
        buffer.append(input)
        if buffer.count > capacity {
            // 18 make sure not to buffer more than the requested capacity
            buffer.removeFirst()
        }
        // 19 deliver the result to the subscriber
        emitAsNeeded()
    }
    
    func receive(completion: Subscribers.Completion<Failure>) {
        guard let subscriber = subscriber else { return }
        self.subscriber = nil
        self.buffer.removeAll()
        subscriber.receive(completion: completion)
    }
}

// Here is the publishers code
extension Publishers {
    // 20 Be able to share a single instance of this operator, so you use a class instead of a struct.
    final class ShareReplay<Upstream: Publisher>: Publisher {
        // 21 This new publisher doesn’t change the output or failure types of the upstream publisher – it simply uses the upstream’s types.
        typealias Output = Upstream.Output
        typealias Failure = Upstream.Failure
        
        // 22 Because you’re going to be feeding multiple subscribers at the same time, you’ll need a lock to guarantee exclusive access to your mutable variables.
        private let lock = NSRecursiveLock()
        
        // 23 Keeps a reference to the upstream publisher. You’ll need it at various points in the subscription lifecycle.
        private let upstream: Upstream
        // 24“You specify the maximum recording capacity of your replay buffer during initialization.
        private let capacity: Int
        // 25 Naturally, you’ll also need storage for the recorded values.
        private var replay = [Output]()
        // 26 You feed multiple subscribers, so you’ll need to keep them around to notify them of events. Each subscriber gets its value from a dedicated ShareReplaySubscription — you’re going to code this in a short while.
        private var subscriptions = [ShareReplaySubscription<Output, Failure>]()
        // 27 “The operator can replay values even after completion, so you need to remember whether the upstream publisher completed.
        private var completion: Subscribers.Completion<Failure>? = nil
        
        init(upstream: Upstream, capacity: Int) {
            self.upstream = upstream
            self.capacity = capacity
        }
        
        private func relay(_ value: Output) {
            // 28 Since multiple subscribers share this publisher, you must protect access to mutable variables with locks. Using defer here is not strictly needed, but it’s good practice just in case you later modify the method, add an early return statement and forget to unlock your lock.
            lock.lock()
            defer { lock.unlock() }
            
            // 29 “Only relays values if the upstream hasn’t completed yet.
            guard completion == nil else { return }
            
            // 30 Adds the value to the rolling buffer and only keeps the latest values of capacity. These are the ones to replay to new subscribers.
            replay.append(value)
            if replay.count > capacity {
                replay.removeFirst()
            }
            
            // 31 “Relays the buffered values to each connected subscriber.
            subscriptions.forEach {
                _ = $0.receive(value)
            }
            
        }
        
        //Letting your publisher when its done:
        private func complete(_ completion: Subscribers.Completion<Failure>) {
            lock.lock()
            defer { lock.unlock() }
            // 32 “Saving the completion event for future subscribers.
            
            self.completion = completion
            // 33 “Relaying it to each connected subscriber.
            subscriptions.forEach {
                _ = $0.receive(completion: completion)
            }
        }
        
        //this method will receive a subscriber. Its duty is to create a new subscription and then hand it over to the subscriber
        func receive<S: Subscriber>(subscriber: S) where Failure == S.Failure, Output == S.Input {
            lock.lock()
            defer { lock.unlock() }
            //34
            let subscription = ShareReplaySubscription(
                subscriber: subscriber,
                replay: replay,
                capacity: capacity,
                completion: completion)
            
            // 35 You keep the subscription around to pass future events to it.
            subscriptions.append(subscription)
            
            // 36 You send the subscription to the subscriber, which may — either now or later — start requesting values.
            subscriber.receive(subscription: subscription)
            
            // 37 “Subscribe only once to the upstream publisher.”
            guard subscriptions.count == 1 else { return }
            
            let sink = AnySubscriber(
                // 38 “Use the handy AnySubscriber class which takes closures, and immediately request .unlimited values upon subscription to let the publisher run to completion.
                receiveSubscription: { subscription in
                    subscription.request(.unlimited)
            },
                //39 “Relay values you receive to downstream subscribers.
                receiveValue: { [weak self] (value: Output) -> Subscribers.Demand in
                    self?.relay(value)
                    return .none
                },
                //40 “Complete your publisher with the completion event you get from upstream.”
                receiveCompletion: { [weak self] in
                    self?.complete($0)
                }
            )
            
            upstream.subscribe(sink)
        }
    }
}
        
        

extension Publisher {
    func shareReplay(capacity: Int = .max) -> Publishers.ShareReplay<Self> {
        return Publishers.ShareReplay(upstream: self, capacity: capacity)
    }
}

// 41 Use the handy TimeLogger object defined in this playground.
var logger = TimeLogger(sinceOrigin: true)
// 42 To simulate sending values at different times, you use a subject.
let subject = PassthroughSubject<Int,Never>()
// 43 Share the subject and replay the last two values only.
let publisher = subject
    .print("shareReplay")
    .shareReplay(capacity: 2)
// 44 Send an initial value through the subject. No subscriber has connected to the shared publisher, so you shouldn’t see any output.
subject.send(0)

let subscription1 = publisher.sink(
    receiveCompletion: {
        print("subscription2 completed: \($0)", to: &logger)
},
    receiveValue: {
        print("subscription2 received \($0)", to: &logger)
}
)

subject.send(1)
subject.send(2)
subject.send(3)

let subscription2 = publisher.sink(
    receiveCompletion: {
        print("subscription2 completed: \($0)", to: &logger)
},
    receiveValue: {
        print("subscription2 received \($0)", to: &logger)
}
)

subject.send(4)
subject.send(5)
subject.send(completion: .finished)

var subscription3: Cancellable? = nil

DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    print("Subscribing to shareReplay after upstream completed")
    subscription3 = publisher.sink(
        receiveCompletion: {
            print("subscription3 completed: \($0)", to: &logger)
    },
        receiveValue: {
            print("subscription3 received \($0)", to: &logger)
    }
    )
}

//######### OUTPUT ######################
//“0.02967s: subscription1 received 1
//+0.03092s: subscription1 received 2
//+0.03189s: subscription1 received 3
//+0.03309s: subscription2 received 2
//+0.03317s: subscription2 received 3
//+0.03371s: subscription1 received 4
//+0.03401s: subscription2 received 4
//+0.03515s: subscription1 received 5
//+0.03548s: subscription2 received 5
//+0.03716s: subscription1 completed: finished
//+0.03746s: subscription2 completed: finished
//Subscribing to shareReplay after upstream completed
//+1.12007s: subscription3 received 4
//+1.12015s: subscription3 received 5
//+1.12057s: subscription3 completed: finished

//Your new operator is working beautifully:
//The 0 value never appears in the logs, because it was emitted before the first subscriber subscribed to the shared publisher.
//Every value propagates to current and future subscribers.
//You created subscription2 after three values have passed through the subject, so it only sees the last two (values 2 and 3)
//You created subscription3 after the subject has completed, but the subscription still received the last two values that the subject emitted.
//The completion event propagates correctly, even if the subscriber comes after the shared publisher has completed.


//“Fantastic! This works exactly as you wanted. Or does it? How can you verify that the publisher is being subscribed to only once? By using the print(_:) operator, of course! You can try it by inserting it before shareReplay.”
// To print use:
//“let publisher = subject
//  .print("shareReplay")
//  .shareReplay(capacity: 2)”

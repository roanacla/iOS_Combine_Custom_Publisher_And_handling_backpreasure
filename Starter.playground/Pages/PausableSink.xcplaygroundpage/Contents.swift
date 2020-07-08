import Combine
import Foundation

protocol Pausable {
  var paused: Bool { get }
  func resume()
}

// 1 Is a class because you don't want the object to be copie (in case you use struct)
final class PausableSubscriber<Input, Failure: Error>:
  Subscriber, Pausable, Cancellable {
  // 2 The subscriber must provide an identifier
  let combineIdentifier = CombineIdentifier()

  // 3 Return true if it can receive more values.
  let receiveValue: (Input) -> Bool
  // 4 Closure after completition
  let receiveCompletion: (Subscribers.Completion<Failure>) -> Void

  // 5 This variable keeps a subscription. Make sure to set it to nil when you don't need the susbcription anymore to avoid retain cycles.
  private var subscription: Subscription? = nil
  // 6 adopt puase due Pausable protocol.
  var paused = false

  // 7 here is where you instantiate the sink method of a subscriber.
  init(receiveValue: @escaping (Input) -> Bool,
       receiveCompletion: @escaping (Subscribers.Completion<Failure>) -> Void) {
    self.receiveValue = receiveValue
    self.receiveCompletion = receiveCompletion
  }

  // 8 Cancel the subscription
  func cancel() {
    subscription?.cancel()
    subscription = nil
  }

  func receive(subscription: Subscription) {
    // 9 store the subscription so later you can resume it.
    self.subscription = subscription
    // 10 request values 1 by 1.  Mostly to catch the pause.
    subscription.request(.max(1))
  }

  func receive(_ input: Input) -> Subscribers.Demand {
    // 11 “call receiveValue and update the paused status accordingly.
    paused = receiveValue(input) == false
    // 12 if is paused, return none. otherwise just one value.
    return paused ? .none : .max(1)
  }

  func receive(completion: Subscribers.Completion<Failure>) {
    // 13 upon completion call receive completion and set subscription to nil.
    receiveCompletion(completion)
    subscription = nil
  }
  //Iimpelement pausable protocol
  func resume() {
    guard paused else { return }

    paused = false
    // 14 if publisher is paused, request one value to start the cycle again.
    subscription?.request(.max(1))
  }
}

extension Publisher {
  // 15 Your pausableSink operator is very close to the sink operator. The only difference is the return type for the receiveValue closure: Bool.
  func pausableSink(
    receiveCompletion: @escaping ((Subscribers.Completion<Failure>) -> Void),
    receiveValue: @escaping ((Output) -> Bool))
    -> Pausable & Cancellable {
    // 16 Instantiate a new PausableSubscriber and subscribe it to self, the publisher.
    let pausable = PausableSubscriber(
      receiveValue: receiveValue,
      receiveCompletion: receiveCompletion)
    self.subscribe(pausable)
    // 17 “The subscriber is the object you’ll use to resume and cancel the subscription.”
    return pausable
  }
}

//################## TESTING YOUr NEW PAUSABLE_SINK #######################
let subscription = [1, 2, 3, 4, 5, 6]
  .publisher
  .pausableSink(receiveCompletion: { completion in
    print("Pausable subscription completed: \(completion)")
  }) { value -> Bool in
    print("Receive value: \(value)")
    if value % 2 == 1 {
      print("Pausing")
      return false
    }
    return true
}
//To resume the publisher, you need to call resume() asynchronously. This is easy to do with a timer. Add this code to set up a timer:

let timer = Timer.publish(every: 1, on: .main, in: .common)
  .autoconnect()
  .sink { _ in
    guard subscription.paused else { return }
    print("Subscription is paused, resuming")
    subscription.resume()
  }

// ####################### OUTPUT #################################
//Receive value: 1
//Pausing
//Subscription is paused, resuming
//Receive value: 2
//Receive value: 3
//Pausing
//Subscription is paused, resuming
//Receive value: 4
//Receive value: 5
//Pausing
//Subscription is paused, resuming
//Receive value: 6
//Pausable subscription completed: finished

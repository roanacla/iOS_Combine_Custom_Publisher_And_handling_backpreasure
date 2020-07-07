import Combine

extension Publisher {
  // 1 The T is to specify Generics. CompactMap<Upstream, Output> is equivalent now to CompactMap<Self, T> plus the conditional Output == Optional<T>
  func unwrap<T>() -> Publishers.CompactMap<Self, T> where Output == Optional<T> {
    // 2
    compactMap { $0 }
  }
}

let values: [Int?] = [1, 2, nil, 3, nil, 4]

values.publisher
  .unwrap()
  .sink {
    print("Received value: \($0)")
  }

//########### OUTPUT #############
//Received value: 1
//Received value: 2
//Received value: 3
//Received value: 4

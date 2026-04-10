public enum BinarySearchResult<Index, Element> {
	case found(index: Index, value: Element)
	case insert(at: Index)

	public var value: Element? {
		switch self {
		case .found(index: _, value: let value):
			value
		case .insert:
			nil
		}
	}
}

public extension RandomAccessCollection {
	// https://stackoverflow.com/questions/31904396/swift-binary-search-for-standard-array

	/// Finds such index N that predicate is true for all elements up to
	/// but not including the index N, and is false for all elements
	/// starting with index N.
	/// Behavior is undefined if there is no such N.
	func binarySearch<SearchValue: Comparable>(
		for query: SearchValue,
		transform: (Element) -> SearchValue
	) -> BinarySearchResult<Index, Element> {
		var low = startIndex
		var high = endIndex
		while low != high {
			let mid = index(low, offsetBy: distance(from: low, to: high) / 2)

			let element = self[mid]
			let value = transform(self[mid])
			if value == query {
				return .found(index: mid, value: element)
			} else if value < query {
				low = index(after: mid)
			} else {
				high = mid
			}
		}

		return .insert(at: low)
	}
}

public struct Frames<Element> {
	private var data: [FrameData<Element>] = []

	public init() {}
}

extension Frames: Collection {
	public func index(after i: Index) -> Index {
		.init(rawValue: data.index(after: i.rawValue))
	}

	public subscript(position: Index) -> Element {
		_read {
			yield data[position.rawValue].value
		}
	}

	public struct Index: Comparable {
		fileprivate var rawValue: Int

		public static func < (lhs: Frames<Element>.Index, rhs: Frames<Element>.Index) -> Bool {
			lhs.rawValue < rhs.rawValue
		}
	}

	public var startIndex: Index {
		.init(rawValue: data.startIndex)
	}

	public var endIndex: Index {
		.init(rawValue: data.endIndex)
	}
}

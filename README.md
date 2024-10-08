# SharedTaskExecutor

Swift package that implements a shared task executor. Performs a predefined asynchronous operation using dynamically created child tasks, sharing the same task between identical requests.

## Examples
### Loading data from the internet
The following code shows how to load data using URLSession without making multiple simultaneous requests for the same URL.

```swift
let loader = SharedTaskExecutor { (url: URL) in
	return try await URLSession.shared.data(from: url)
}

// make multiple simultaneous requests, some to the same URL
async let result1 = loader.performWithSharedTask(request: URL("https://example.com/some/resource")!)
async let result2 = loader.performWithSharedTask(request: URL("https://example.com/some/resource")!)
async let result3 = loader.performWithSharedTask(request: URL("https://example.com/a/different/thing")!)

// Even though we called it three times, the first two were for identical URLs, so only one request will be made to `/some/resource` and one to `/a/different/thing`. Both calls to `/some/resource` will return at the same time.
```

### Image loader with caching
The following code implements a basic image loader that batches requests to load the same image, and caches the decoded images so only one request is ever made per URL.

A 500 millisecond grace period means that if a request for a particular URL is cancelled and another request for the same image is made within 500 milliseconds, the load task will not be cancelled and the second request will pick up where the first left off. This is useful e.g. for loading images in a lazy stack where the user might scroll back and forth rapidly.

```swift
let cache = NSCache<NSURL, UIImage>()
let loader = SharedTaskExecutor<URL, UIImage?>(gracePeriod: .milliseconds(500)) { url in
	if let cachedImage = cache.object(forKey: url as NSURL) {
		return cachedImage
	} else {
		let (data, httpResponse) = try await URLSession.shared.data(from: url)
		guard let image = UIImage(data: data) else { return nil }
		cache.setObject(image, forKey: url as NSURL)
		return image
	}
}
```

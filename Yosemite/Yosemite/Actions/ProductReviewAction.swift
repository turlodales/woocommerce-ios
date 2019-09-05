import Foundation
import Networking


/// ProductReviewAction: Defines all of the Actions supported by the ProductReviewStore.
///
public enum ProductReviewAction: Action {

    /// Synchronizes the ProductReviews matching the specified criteria.
    ///
    case synchronizeProductReviews(siteID: Int, pageNumber: Int, pageSize: Int, onCompletion: (Error?) -> Void)

    /// Retrieves the specified ProductReview.
    ///
    case retrieveProductReview(siteID: Int, reviewID: Int, onCompletion: (ProductReview?, Error?) -> Void)

    /// Deletes all of the cached product reviews.
    ///
    case resetStoredProductReviews(onCompletion: () -> Void)
}
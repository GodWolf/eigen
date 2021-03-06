import Foundation
import Interstellar

protocol AuctionNetworkModelType {
    var bidders: [Bidder] { get }

    func fetch() -> Observable<Result<SaleViewModel>>
    func fetchSale(_ saleID: String) -> Observable<Result<Sale>>
    func fetchSaleArtworks(_ saleID: String) -> Observable<Result<[SaleArtwork]>>
    func fetchBidders(_ saleID: String) -> Observable<Result<[Bidder]>>
    func fetchLotStanding(_ saleID: String) -> Observable<Result<[LotStanding]>>
}

typealias PromotedSaleArtworks = [SaleArtwork]

/// Network model for everything auction-related. It delegates out to other
/// network models and doesn't itself perform any networking.
class AuctionNetworkModel {
    let saleID: String
    var saleModel: Sale?
    var saleViewModel: SaleViewModel?

    // Each one of these network models performs their request to fetch exactly one thing,
    // and then store it locally.
    lazy var saleNetworkModel: AuctionSaleNetworkModelType
        = AuctionSaleNetworkModel()
    lazy var saleArtworksNetworkModel: AuctionSaleArtworksNetworkModelType
        = AuctionSaleArtworksNetworkModel()
    lazy var bidderNetworkModel: AuctionBiddersNetworkModelType
        = AuctionBiddersNetworkModel()
    lazy var lotStandingsNetworkModel: AuctionLotStandingsNetworkModel
        = AuctionLotStandingsNetworkModel()

    init(saleID: String) {
        self.saleID = saleID
    }
}

extension AuctionNetworkModel: AuctionNetworkModelType {
    var bidders: [Bidder] {
        return bidderNetworkModel.bidders
    }

    func fetchSale(_ saleID: String) -> Observable<Result<Sale>> {
        return saleNetworkModel.fetchSale(saleID)
    }

    func fetchSaleArtworks(_ saleID: String) -> Observable<Result<[SaleArtwork]>> {
        return self.saleArtworksNetworkModel.fetchSaleArtworks(saleID)
    }

    func skipFetchForSaleArtworks() -> Observable<Result<[SaleArtwork]>> {
        return Observable(Result(success: Array<SaleArtwork>()))
    }


    func fetchBidders(_ saleID: String) -> Observable<Result<[Bidder]>> {
        let signal = Observable(saleID)
        return signal.flatMap(bidderNetworkModel.fetchBiddersForSale)
    }

    func fetchLotStanding(_ saleID: String) -> Observable<Result<[LotStanding]>> {
        return lotStandingsNetworkModel.fetch(saleID)
    }

    func fetch() -> Observable<Result<SaleViewModel>> {
        let saleID = self.saleID

        return fetchSale(saleID)
            .flatMap { (sale: Result<Sale>) -> Observable<(
                Result<Sale>,
                Result<[SaleArtwork]>,
                Result<PromotedSaleArtworks>,
                Result<[Bidder]>,
                Result<[LotStanding]>)> in

                switch sale {
                case .success(let sale):
                    return combine(
                        Observable(Result(success: sale)),
                        self.fetchSaleArtworks(self.saleID),
                        sale.promotedSaleID != nil ? self.fetchSaleArtworks(sale.promotedSaleID) : self.skipFetchForSaleArtworks(),
                        self.fetchBidders(self.saleID),
                        self.fetchLotStanding(self.saleID)
                    )
                case .error(let error):
                    print(error)

                    // FIXME: Update this return value
                    // return Observable<Any>(Result.error(error), Result.error(error), Result.error(error), Result.error(error), Result.error(error))
                    fatalError()
                }
            }
            .flatMap { [weak self] (
                sale,
                saleArtworks,
                promotedSaleArtworks,
                bidders,
                lotStandings
            ) -> Observable<Result<SaleViewModel>> in
                guard let `self` = self else { return Observable() }

                var retrievedLotStandings = [LotStanding]()

                // Note: we're discarding any error in lotStandings because our
                // UI doesn't expose errors.
                if case .success(let lotStandings) = lotStandings {
                    retrievedLotStandings = lotStandings
                }

                switch bidders {
                case .success(let bidders):
                    return Observable(
                        self.createViewModel(
                            sale: sale,
                            saleArtworks: saleArtworks,
                            promotedSaleArtworks: promotedSaleArtworks,
                            bidders: bidders,
                            lotStandings: retrievedLotStandings
                        )
                    )
                case .error(let error):
                    return Observable(.error(error))
                }

            }
            .next { (saleViewModel: SaleViewModel) in
                self.saleViewModel = saleViewModel
            }
    }

    func createViewModel(
        sale: Result<Sale>,
        saleArtworks: Result<[SaleArtwork]>,
        promotedSaleArtworks: Result<PromotedSaleArtworks>,
        bidders: [Bidder],
        lotStandings: [LotStanding]
    ) -> Result<SaleViewModel> {

        // We need to extract them from their respective Result containers. If
        // either failed, we pass along that failure.
        switch (sale, saleArtworks, promotedSaleArtworks) {

        case (.success(let sale),
              .success(let saleArtworks),
              .success(let promotedSaleArtworks)):

            saleArtworks.forEach {
                $0.auction = sale
            }

            promotedSaleArtworks.forEach {
                $0.auction = sale
            }

            return .success(
                SaleViewModel(
                    sale: sale,
                    saleArtworks: saleArtworks,
                    promotedSaleArtworks: promotedSaleArtworks,
                    bidders: bidders,
                    lotStandings: lotStandings
                )
            )

        case (.error(let error), .error, _):
            // Need to pick one error, might as well go with the first.
            return .error(error)

        case (.error(let error), .success, _):
            return .error(error)

        case (.success, .error(let error), _):
            return .error(error)

        case (.success(_), .success(_), .error(let error)):
            return .error(error)
        }
    }
}

// Interstellar's merge() runs in sequence, this combine() runs in parallel.
// It's ugly but it works.
func combine<A, B, C, D, E>(
    _ a: Observable<Result<A>>,
    _ b: Observable<Result<B>>,
    _ c: Observable<Result<C>>,
    _ d: Observable<Result<D>>,
    _ e: Observable<Result<E>>
    ) -> Observable<(Result<A>, Result<B>, Result<C>, Result<D>, Result<E>)> {

    var aResult: Result<A>?
    var bResult: Result<B>?
    var cResult: Result<C>?
    var dResult: Result<D>?
    var eResult: Result<E>?

    let observable = Observable<(
        Result<A>,
        Result<B>,
        Result<C>,
        Result<D>,
        Result<E>)>()

    let notifyIfComplete: () -> Void = {
        if  let aResult = aResult,
            let bResult = bResult,
            let cResult = cResult,
            let dResult = dResult,
            let eResult = eResult
        {
            observable.update((aResult, bResult, cResult, dResult, eResult))
        }
    }

    a.subscribe { result in
        aResult = result
        notifyIfComplete()
    }
    b.subscribe { result in
        bResult = result
        notifyIfComplete()
    }
    c.subscribe { result in
        cResult = result
        notifyIfComplete()
    }
    d.subscribe { result in
        dResult = result
        notifyIfComplete()
    }
    e.subscribe { result in
        eResult = result
        notifyIfComplete()
    }

    return observable
}

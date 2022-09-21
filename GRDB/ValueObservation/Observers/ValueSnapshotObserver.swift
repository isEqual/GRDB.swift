import Foundation

/// `ValueSnapshotObserver` observes the database for
/// `SnapshotObservation`, in a `DatabasePool`.
///
/// It performs the following database observation cycle:
///
/// 1. Start observation or detect a database change
/// 2. Fetch (from a snapshot)
/// 3. Reduce
/// 4. Notify
///
/// **Fetch** is performed concurrently (hence the name of this observer).
///
/// **Reduce** is the operation that turns the fetched database values into the
/// observed values. Those are not the same. Consider, for example, the `map()`
/// and `removeDuplicates()` operators: they perform their job during the
/// reducing stage.
///
/// **Notify** is calling user callbacks, in case of database change or error.
final class ValueSnapshotObserver<Reducer: SnapshotReducer> {
    // MARK: - Configuration
    //
    // Configuration is not mutable.
    
    /// How to schedule observed values and errors.
    private let scheduler: ValueObservationScheduler
    
    /// Configures the tracked database region.
    private let trackingMode: ValueObservationTrackingMode
    
    // MARK: - Mutable State
    //
    // The observer has four distinct mutable states that evolve independently,
    // and are made thread-safe with various mechanisms:
    //
    // - A `DatabaseAccess`: ability to access the database. It is constant but
    //   turns nil after the observation fails or is cancelled, in order to
    //   release memory and resources when the observation completes. It is
    //   guarded by `lock`, because observation can fail or be cancelled from
    //   multiple threads.
    //
    // - A `NotificationCallbacks`: ability to notify observation events. It is
    //   constant but turns nil when failure or cancellation is notified, in
    //   order to release memory and resources when the observation completes.
    //   It is guarded by `lock`, because observation can fail or be cancelled
    //   from multiple threads.
    //
    // - An `ObservationState`: relationship with the `TransactionObserver`
    //   protocol. It is only accessed from the serialized writer
    //   dispatch queue.
    //
    // - A `Reducer`: the observation reducer, only accessed from the
    //   serialized dispatch queue `reduceQueue`.
    //
    // The `reduceQueue` guarantees that fresh value notifications have the same
    // order as transactions. It is different from the serialized writer
    // dispatch queue because we do not want to lock the database as
    // computations (`map`, `removeDuplicates()`, etc.) are performed.
    //
    // Despite being protected by the same lock, `DatabaseAccess` and
    // `NotificationCallbacks` are not merged together. This is because the
    // observer does not lose `DatabaseAccess` at the same time it
    // looses `NotificationCallbacks`:
    //
    // - In case of cancellation, `NotificationCallbacks` is lost first, and
    //   `DatabaseAccess` is lost asynchronously, after the observer could
    //   resign as a transaction observer. See `cancel()`.
    //
    // - In case of error, `DatabaseAccess` may be lost synchronously, and
    //   `NotificationCallbacks` is lost asynchronously, after the error could
    //   be notified. See error catching clauses.
    
    /// Ability to access the database
    private struct DatabaseAccess {
        /// The observed DatabasePool.
        let dbPool: DatabasePool
        
        /// A reducer that fetches database values.
        private let reducer: Reducer
        
        init(dbPool: DatabasePool, reducer: Reducer) {
            self.dbPool = dbPool
            self.reducer = reducer
        }
        
        func fetch(_ db: Database, snapshot: DatabaseSnapshot)
        throws -> Reducer.Fetched
        {
            try reducer._fetch(db, snapshot: snapshot)
        }
        
        func fetchRecordingObservedRegion(_ db: Database, snapshot: DatabaseSnapshot)
        throws -> (Reducer.Fetched, DatabaseRegion)
        {
            var region = DatabaseRegion()
            let value = try db.recordingSelection(&region) {
                try reducer._fetch(db, snapshot: snapshot)
            }
            return try (value, region.observableRegion(db))
        }
    }
    
    /// Ability to notify observation events
    private struct NotificationCallbacks {
        let events: ValueObservationEvents
        let onChange: (Reducer.Value) -> Void
    }
    
    /// Relationship with the `TransactionObserver` protocol
    private struct ObservationState {
        var region: DatabaseRegion?
        var isModified = false
        
        static var notObserving: Self { .init(region: nil, isModified: false) }
    }
    
    /// Protects `databaseAccess` and `notificationCallbacks`.
    ///
    /// Check out this compiler bug:
    /// - <https://github.com/groue/GRDB.swift/issues/1026>
    /// - <https://github.com/groue/GRDB.swift/pull/1025>
    private let lock = NSLock()
    
    /// The dispatch queue where database values are reduced into observed
    /// values before being notified. Protects `reducer`.
    private let reduceQueue: DispatchQueue
    
    /// Access to the database, protected by `lock`.
    private var databaseAccess: DatabaseAccess?
    
    /// Ability to notify observation events, protected by `lock`.
    private var notificationCallbacks: NotificationCallbacks?
    
    /// Support for `TransactionObserver`, protected by the serialized writer
    /// dispatch queue.
    private var observationState = ObservationState.notObserving
    
    /// Protected by `reduceQueue`.
    private var reducer: Reducer
    
    init(
        dbPool: DatabasePool,
        scheduler: ValueObservationScheduler,
        trackingMode: ValueObservationTrackingMode,
        reducer: Reducer,
        events: ValueObservationEvents,
        onChange: @escaping (Reducer.Value) -> Void)
    {
        // Configuration
        self.scheduler = scheduler
        self.trackingMode = trackingMode
        
        // State
        self.databaseAccess = DatabaseAccess(
            dbPool: dbPool,
            // ValueReducer semantics guarantees that reducer._fetch
            // is independent from the reducer state
            reducer: reducer)
        self.notificationCallbacks = NotificationCallbacks(events: events, onChange: onChange)
        self.reducer = reducer
        self.reduceQueue = DispatchQueue(
            label: dbPool.configuration.identifier(
                defaultLabel: "GRDB",
                purpose: "ValueObservation"),
            qos: dbPool.configuration.readQoS)
    }
}

// MARK: - Starting the Observation
//
// When we start an observation from a `DatabasePool`, we do not wait for an
// access to the writer connection before fetching the initial value. That is
// because the user of a `DatabasePool` expects to be notified with the initial
// value as fast as possible, even if a long write transaction is running in the
// background.
//
// We will thus perform the initial fetch from a reader connection, and only
// then access the writer connection, and start database observation.
//
// Between this initial fetch, and the beginning of database observation, any
// number of unobserved writes may occur. We must notify the changes that happen
// during this unobserved window. But how do we spot them, since we were not
// observing the database yet?
//
// The solution depends on the presence of the `SQLITE_ENABLE_SNAPSHOT`
// SQLite compilation flag.
//
// Without `SQLITE_ENABLE_SNAPSHOT`, we have NO WAY to detect if the database
// was changed or not between the initial fetch and the beginning of database
// observation. We will thus always perform a secondary fetch from the initial
// access to the writer connection. Even if no change was performed. We may end
// up notifying the same value twice. Such stuttering is a documented glitch,
// and the user can perform deduplication with the
// `removeDuplicates()` operator.
//
// With `SQLITE_ENABLE_SNAPSHOT`, we can detect if the database was not changed
// at all between the initial fetch and the beginning of database observation.
// If the database was changed, we perform a secondary fetch from the initial
// access to the writer connection. It is possible that the change was not
// related to the observed value. Actually we have NO WAY to know. So we may end
// up notifying the same value twice. Such stuttering is a documented glitch,
// and the user can perform deduplication with the
// `removeDuplicates()` operator.
//
// This is how we can both:
// 1. Start the observation without waiting for a write access (the expected
//    benefit of `DatabasePool`).
// 2. Make sure we do not miss a change (a documented guarantee)
//
// Support for `SQLITE_ENABLE_SNAPSHOT` is implemented by our
// `WALSnapshot` class.
extension ValueSnapshotObserver {
    // Starts the observation
    func start() -> AnyDatabaseCancellable {
        let (notificationCallbacks, databaseAccess) = lock.synchronized {
            (self.notificationCallbacks, self.databaseAccess)
        }
        guard let notificationCallbacks, let databaseAccess else {
            // Likely a GRDB bug: during a synchronous start, user is not
            // able to cancel observation.
            fatalError("can't start a cancelled or failed observation")
        }
        
        if scheduler.immediateInitialValue() {
            do {
                // Start the observation in an synchronous way
                let initialValue = try syncStart(from: databaseAccess)
                
                // Notify the initial value from the dispatch queue the
                // observation was started from
                notificationCallbacks.onChange(initialValue)
            } catch {
                // Notify error from the dispatch queue the observation
                // was started from.
                notificationCallbacks.events.didFail?(error)
                
                // Early return!
                return AnyDatabaseCancellable { /* nothing to cancel */ }
            }
        } else {
            // Start the observation in an asynchronous way
            asyncStart(from: databaseAccess)
        }
        
        // Make sure the returned cancellable cancels the observation
        // when deallocated. We can't relying on the deallocation of
        // self to trigger early cancellation, because self may be retained by
        // some closure waiting to run in some DispatchQueue.
        return AnyDatabaseCancellable(self)
    }
    
    private func startObservation(_ writerDB: Database, observedRegion: DatabaseRegion) {
        observationState.region = observedRegion
        assert(observationState.isModified == false)
        writerDB.add(transactionObserver: self, extent: .observerLifetime)
    }
}

// MARK: - Starting the Observation (with SQLITE_ENABLE_SNAPSHOT)

extension ValueSnapshotObserver {
    /// Synchronously starts the observation, and returns the initial value.
    ///
    /// Unlike `asyncStart()`, this method does not notify the initial value or error.
    private func syncStart(from databaseAccess: DatabaseAccess) throws -> Reducer.Value {
        let initialSnapshot = try databaseAccess.dbPool.makeSnapshot()
        let (fetchedValue, initialRegion, initialWALSnapshot) = try initialSnapshot.read {
            db -> (Reducer.Fetched, DatabaseRegion, WALSnapshot?) in
            // swiftlint:disable:previous closure_parameter_position
            
            switch trackingMode {
            case let .constantRegion(regions):
                let fetchedValue = try initialSnapshot.read { db in
                    try databaseAccess.fetch(db, snapshot: initialSnapshot)
                }
                let region = try DatabaseRegion.union(regions)(db)
                let initialRegion = try region.observableRegion(db)
                return (fetchedValue, initialRegion, WALSnapshot(db))
                
            case .constantRegionRecordedFromSelection:
                let (fetchedValue, initialRegion) = try databaseAccess
                    .fetchRecordingObservedRegion(db, snapshot: initialSnapshot)
                return (fetchedValue, initialRegion, WALSnapshot(db))
                
            case .nonConstantRegionRecordedFromSelection:
                // Likely a GRDB bug
                fatalError("ValueSnapshotObserver does not support non constant observed regions.")
            }
        }
        
        // Reduce
        let initialValue = try reduceQueue.sync {
            guard let initialValue = try reducer._value(fetchedValue) else {
                fatalError("Broken contract: reducer has no initial value")
            }
            return initialValue
        }
        
        // Start observation
        asyncStartObservation(
            from: databaseAccess,
            initialSnapshot: initialSnapshot,
            initialWALSnapshot: initialWALSnapshot,
            initialRegion: initialRegion)
        
        return initialValue
    }
    
    /// Asynchronously starts the observation
    ///
    /// Unlike `syncStart()`, this method does notify the initial value or error.
    private func asyncStart(from databaseAccess: DatabaseAccess) {
        do {
            let initialSnapshot = try databaseAccess.dbPool.makeSnapshot()
            initialSnapshot.asyncRead { dbResult in
                let isNotifying = self.lock.synchronized { self.notificationCallbacks != nil }
                guard isNotifying else { return /* Cancelled */ }
                
                do {
                    // Fetch
                    let fetchedValue: Reducer.Fetched
                    let initialRegion: DatabaseRegion
                    let db = try dbResult.get()
                    switch self.trackingMode {
                    case let .constantRegion(regions):
                        fetchedValue = try databaseAccess.fetch(db, snapshot: initialSnapshot)
                        let region = try DatabaseRegion.union(regions)(db)
                        initialRegion = try region.observableRegion(db)
                        
                    case .constantRegionRecordedFromSelection:
                        (fetchedValue, initialRegion) = try databaseAccess
                            .fetchRecordingObservedRegion(db, snapshot: initialSnapshot)
                        
                    case .nonConstantRegionRecordedFromSelection:
                        // Likely a GRDB bug
                        fatalError("ValueSnapshotObserver does not support non constant observed regions.")
                    }
                    
                    // Reduce
                    //
                    // Reducing is performed asynchronously, so that we do not lock
                    // a database dispatch queue longer than necessary.
                    self.reduceQueue.async {
                        let isNotifying = self.lock.synchronized { self.notificationCallbacks != nil }
                        guard isNotifying else { return /* Cancelled */ }
                        
                        do {
                            guard let initialValue = try self.reducer._value(fetchedValue) else {
                                fatalError("Broken contract: reducer has no initial value")
                            }
                            
                            // Notify
                            self.scheduler.schedule {
                                let onChange = self.lock.synchronized { self.notificationCallbacks?.onChange }
                                guard let onChange else { return /* Cancelled */ }
                                onChange(initialValue)
                            }
                        } catch {
                            self.notifyError(error)
                        }
                    }
                    
                    // Start observation
                    self.asyncStartObservation(
                        from: databaseAccess,
                        initialSnapshot: initialSnapshot,
                        initialWALSnapshot: WALSnapshot(db),
                        initialRegion: initialRegion)
                } catch {
                    self.notifyError(error)
                }
            }
        } catch {
            self.notifyError(error)
        }
    }
    
    private func asyncStartObservation(
        from databaseAccess: DatabaseAccess,
        initialSnapshot: DatabaseSnapshot,
        initialWALSnapshot: WALSnapshot?,
        initialRegion: DatabaseRegion)
    {
        databaseAccess.dbPool.asyncWriteWithoutTransaction { writerDB in
            let events = self.lock.synchronized { self.notificationCallbacks?.events }
            guard let events else { return /* Cancelled */ }
            
            do {
                var observedRegion = initialRegion
                
                // Transaction is needed for comparing version snapshots
                try writerDB.isolated(readOnly: true) {
                    // Keep DatabaseSnaphot alive until we have compared
                    // database versions. It prevents database checkpointing,
                    // and keeps WAL snapshots (`sqlite3_snapshot`) valid
                    // and comparable.
                    let isModified = withExtendedLifetime(initialSnapshot) {
                        guard let initialWALSnapshot,
                              let currentWALSnapshot = WALSnapshot(writerDB)
                        else {
                            return true
                        }
                        let ordering = initialWALSnapshot.compare(currentWALSnapshot)
                        assert(ordering <= 0, "Unexpected snapshot ordering")
                        return ordering < 0
                    }
                    
                    if isModified {
                        events.databaseDidChange?()
                        
                        // Fetch
                        let fetchedValue: Reducer.Fetched
                        
                        switch self.trackingMode {
                        case .constantRegion:
                            let snapshot = try databaseAccess.dbPool.makeSnapshot()
                            fetchedValue = try snapshot.read { db in
                                try databaseAccess.fetch(db, snapshot: snapshot)
                            }
                            events.willTrackRegion?(initialRegion)
                            self.startObservation(writerDB, observedRegion: initialRegion)
                            
                        case .constantRegionRecordedFromSelection:
                            let snapshot = try databaseAccess.dbPool.makeSnapshot()
                            (fetchedValue, observedRegion) = try snapshot.read { db in
                                try databaseAccess.fetchRecordingObservedRegion(db, snapshot: snapshot)
                            }
                            events.willTrackRegion?(observedRegion)
                            self.startObservation(writerDB, observedRegion: observedRegion)
                            
                        case .nonConstantRegionRecordedFromSelection:
                            // Likely a GRDB bug
                            fatalError("ValueSnapshotObserver does not support non constant observed regions.")
                        }
                        
                        // Reduce
                        //
                        // Reducing is performed asynchronously, so that we do not lock
                        // the writer dispatch queue longer than necessary.
                        //
                        // Important: reduceQueue.async guarantees the same ordering
                        // between transactions and notifications!
                        self.reduceQueue.async {
                            let isNotifying = self.lock.synchronized { self.notificationCallbacks != nil }
                            guard isNotifying else { return /* Cancelled */ }
                            
                            do {
                                let value = try self.reducer._value(fetchedValue)
                                
                                // Notify
                                if let value = value {
                                    self.scheduler.schedule {
                                        let onChange = self.lock.synchronized { self.notificationCallbacks?.onChange }
                                        guard let onChange else { return /* Cancelled */ }
                                        onChange(value)
                                    }
                                }
                            } catch {
                                let dbPool = self.lock.synchronized { self.databaseAccess?.dbPool }
                                dbPool?.asyncWriteWithoutTransaction { writerDB in
                                    self.stopDatabaseObservation(writerDB)
                                }
                                self.notifyError(error)
                            }
                        }
                    } else {
                        events.willTrackRegion?(initialRegion)
                        self.startObservation(writerDB, observedRegion: initialRegion)
                    }
                }
            } catch {
                self.notifyError(error)
            }
        }
    }
}

// MARK: - Observing Database Transactions

extension ValueSnapshotObserver: TransactionObserver {
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        if let region = observationState.region {
            return region.isModified(byEventsOfKind: eventKind)
        } else {
            return false
        }
    }
    
    func databaseDidChange(with event: DatabaseEvent) {
        if let region = observationState.region, region.isModified(by: event) {
            // Database was modified!
            observationState.isModified = true
            // We can stop observing the current transaction
            stopObservingDatabaseChangesUntilNextTransaction()
        }
    }
    
    var commitHandling: CommitHandling {
        // Ignore transaction unless database was modified
        guard observationState.isModified else {
            return .none
        }
        
        let dbPool = lock.synchronized {
            self.databaseAccess?.dbPool
        }
        guard let dbPool else {
            return .none
        }
        
        return .coalescedInSnapshot(dbPool)
//        // No need to share a transaction with other observers
//        return .databaseDidCommit
    }
    
    func databaseDidCommit(_ writerDB: Database) {
        // Reset the isModified flag until next transaction
        assert(observationState.isModified)
        observationState.isModified = false
        
        // Ignore transaction unless we are still notifying database events, and
        // we can still access the database.
        let (events, databaseAccess) = lock.synchronized {
            (notificationCallbacks?.events, self.databaseAccess)
        }
        guard let events, let databaseAccess else { return /* Cancelled */ }
        
        events.databaseDidChange?()
        
        // Fetch
        let future: DatabaseFuture<Reducer.Fetched>
        
        switch trackingMode {
        case .constantRegion, .constantRegionRecordedFromSelection:
            do {
                let snapshot = try databaseAccess.dbPool.makeSnapshot()
                future = snapshot.readFuture { db in
                    try databaseAccess.fetch(db, snapshot: snapshot)
                }
            } catch {
                future = DatabaseFuture(.failure(error))
            }
            
        case .nonConstantRegionRecordedFromSelection:
            // When the tracked region is not constant, we can't fetch the
            // observed value from a snapshot.
            //
            // This is because after the snapshot has acquired snapshot
            // isolation, and before the fetch completes, a change can be
            // performed in the *next* tracked region. When this happens, the
            // snapshot fetch has loaded an obsolete value, and we need to
            // perform a new fetch, with the latest values. But the
            // observation was not triggered by the change because we didn't
            // know that this change was about to be tracked! This means
            // that we'd miss a change, and fail notifying the latest value.
            //
            // Conclusion: non-constant regions are not supported.
            fatalError("ValueSnapshotObserver does not support non constant observed regions.")
        }
        
        // Reduce
        //
        // Reducing is performed asynchronously, so that we do not lock
        // the writer dispatch queue longer than necessary.
        //
        // Important: reduceQueue.async guarantees the same ordering between
        // transactions and notifications!
        reduceQueue.async {
            do {
                // Wait until fetch has completed
                // TODO: find a way to guarantee correct ordering without waiting for a semaphore and blocking a thread.
                let fetchedValue = try future.wait()
                
                let isNotifying = self.lock.synchronized { self.notificationCallbacks != nil }
                guard isNotifying else { return /* Cancelled */ }
                
                let value = try self.reducer._value(fetchedValue)
                
                // Notify value
                if let value = value {
                    self.scheduler.schedule {
                        let onChange = self.lock.synchronized { self.notificationCallbacks?.onChange }
                        guard let onChange else { return /* Cancelled */ }
                        onChange(value)
                    }
                }
            } catch {
                let dbPool = self.lock.synchronized { self.databaseAccess?.dbPool }
                dbPool?.asyncWriteWithoutTransaction { writerDB in
                    self.stopDatabaseObservation(writerDB)
                }
                self.notifyError(error)
            }
        }
    }
    
    func databaseDidRollback(_ db: Database) {
        // Reset the isModified flag until next transaction
        observationState.isModified = false
    }
}

// MARK: - Ending the Observation

extension ValueSnapshotObserver: DatabaseCancellable {
    func cancel() {
        // Notify cancellation
        let (events, dbPool): (ValueObservationEvents?, DatabasePool?) = lock.synchronized {
            let events = notificationCallbacks?.events
            notificationCallbacks = nil
            return (events, databaseAccess?.dbPool)
        }
        
        guard let events else { return /* Cancelled or failed */ }
        events.didCancel?()
        
        // Stop observing the database
        // Do it asynchronously, so that we do not block the current thread:
        // cancellation may be triggered while a long write access is executing.
        guard let dbPool else { return /* Failed */ }
        dbPool.asyncWriteWithoutTransaction { db in
            self.stopDatabaseObservation(db)
        }
    }
    
    func notifyError(_ error: Error) {
        scheduler.schedule {
            let events = self.lock.synchronized {
                let events = self.notificationCallbacks?.events
                self.notificationCallbacks = nil
                return events
            }
            guard let events else { return /* Cancelled */ }
            events.didFail?(error)
        }
    }
    
    private func stopDatabaseObservation(_ writerDB: Database) {
        writerDB.remove(transactionObserver: self)
        observationState = .notObserving
        lock.synchronized {
            databaseAccess = nil
        }
    }
}

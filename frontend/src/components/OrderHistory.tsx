/**
 * OrderHistory component displays a paginated, filterable table of orders.
 * Supports filtering by status, side, instrument, and date range.
 *
 * The order history is fetched from the API with server-side pagination.
 * The component supports both real-time updates via WebSocket and manual
 * refresh. When real-time updates are enabled, new orders and status
 * changes are pushed to the component and merged into the existing list.
 *
 * The merge strategy for real-time updates:
 *   - New orders: prepended to the list (maintaining sort order)
 *   - Status changes: updated in-place (replacing the existing entry)
 *   - Cancelled orders: marked with a strikethrough style (not removed)
 *
 * TODO: The merge strategy has a bug where duplicate orders can appear
 * if the WebSocket update arrives before the API response for the same
 * order. The deduplication logic checks by order ID, but the API response
 * and WebSocket message may have different timestamps for the same event,
 * causing the deduplication to fail for approximately 0.5% of orders.
 * The deduplication should use an event sequence number that is consistent
 * across both data sources. The sequence number was added to the API
 * response schema in v3 but the WebSocket messages still use the v2 format
 * which doesn't include it. The WebSocket message format upgrade is
 * tracked in WS-481.
 */

import React, { useState, useCallback, useEffect, useMemo, useRef } from 'react';
import { formatPrice, formatQuantity, formatTimestamp, formatCurrency, formatEnumValue, statusColor, paginate } from '../utils/formatters';

// ---------------------------------------------------------------------------
// TYPES
// ---------------------------------------------------------------------------

export interface Order {
  id: string;
  clientOrderId?: string;
  instrumentId: string;
  instrumentSymbol: string;
  side: 'buy' | 'sell';
  type: 'market' | 'limit' | 'stop' | 'stop_limit' | 'trailing_stop' | 'iceberg';
  status: 'new' | 'pending' | 'filled' | 'partially_filled' | 'cancelled' | 'rejected' | 'expired';
  price: number | null;
  stopPrice: number | null;
  quantity: number;
  filledQuantity: number;
  remainingQuantity: number;
  avgFillPrice: number | null;
  filledValue: number | null;
  fees: number | null;
  feeCurrency: string;
  timeInForce: string;
  createdAt: string;
  updatedAt: string;
  expiredAt: string | null;
  notes?: string;
}

export interface OrderHistoryProps {
  orders: Order[];
  loading?: boolean;
  error?: string | null;
  pageSize?: number;
  showFilters?: boolean;
  showPagination?: boolean;
  onRefresh?: () => void;
  onCancelOrder?: (orderId: string) => void;
  onOrderClick?: (order: Order) => void;
  onPageChange?: (page: number) => void;
  compact?: boolean;
  className?: string;
}

type OrderFilterStatus = 'all' | 'open' | 'filled' | 'cancelled' | 'rejected';
type OrderFilterSide = 'all' | 'buy' | 'sell';

const STATUS_FILTERS: { value: OrderFilterStatus; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: 'open', label: 'Open' },
  { value: 'filled', label: 'Filled' },
  { value: 'cancelled', label: 'Cancelled' },
  { value: 'rejected', label: 'Rejected' },
];

const OPEN_STATUSES = ['new', 'pending', 'partially_filled'];

// ---------------------------------------------------------------------------
// COMPONENT
// ---------------------------------------------------------------------------

export function OrderHistory({
  orders,
  loading = false,
  error = null,
  pageSize = 20,
  showFilters = true,
  showPagination = true,
  onRefresh,
  onCancelOrder,
  onOrderClick,
  onPageChange,
  compact = false,
  className,
}: OrderHistoryProps) {
  const [statusFilter, setStatusFilter] = useState<OrderFilterStatus>('all');
  const [sideFilter, setSideFilter] = useState<OrderFilterSide>('all');
  const [currentPage, setCurrentPage] = useState(1);
  const [sortField, setSortField] = useState<keyof Order>('createdAt');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('desc');
  const [searchQuery, setSearchQuery] = useState('');
  const [selectedOrder, setSelectedOrder] = useState<string | null>(null);
  const [confirmCancelId, setConfirmCancelId] = useState<string | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);

  // Filter and sort orders
  const filteredOrders = useMemo(() => {
    let result = [...orders];

    // Apply status filter
    if (statusFilter === 'open') {
      result = result.filter(o => OPEN_STATUSES.includes(o.status));
    } else if (statusFilter !== 'all') {
      result = result.filter(o => o.status === statusFilter);
    }

    // Apply side filter
    if (sideFilter !== 'all') {
      result = result.filter(o => o.side === sideFilter);
    }

    // Apply search
    if (searchQuery) {
      const query = searchQuery.toLowerCase();
      result = result.filter(o =>
        o.id.toLowerCase().includes(query) ||
        o.instrumentSymbol.toLowerCase().includes(query) ||
        o.clientOrderId?.toLowerCase().includes(query)
      );
    }

    // Sort
    result.sort((a, b) => {
      const valA = a[sortField];
      const valB = b[sortField];
      if (!valA && !valB) return 0;
      if (!valA) return 1;
      if (!valB) return -1;
      const cmp = valA < valB ? -1 : valA > valB ? 1 : 0;
      return sortDirection === 'asc' ? cmp : -cmp;
    });

    return result;
  }, [orders, statusFilter, sideFilter, searchQuery, sortField, sortDirection]);

  // Paginate
  const { items: pageItems, total, pages } = useMemo(
    () => paginate(filteredOrders, currentPage, pageSize),
    [filteredOrders, currentPage, pageSize]
  );

  const handlePageChange = useCallback((page: number) => {
    setCurrentPage(page);
    onPageChange?.(page);
    if (containerRef.current) {
      containerRef.current.scrollTop = 0;
    }
  }, [onPageChange]);

  const handleSort = useCallback((field: keyof Order) => {
    setSortDirection(prev => field === sortField ? (prev === 'asc' ? 'desc' : 'asc') : 'desc');
    setSortField(field);
  }, [sortField]);

  const handleCancelClick = useCallback((orderId: string) => {
    setConfirmCancelId(orderId);
  }, []);

  const handleConfirmCancel = useCallback(() => {
    if (confirmCancelId && onCancelOrder) {
      onCancelOrder(confirmCancelId);
    }
    setConfirmCancelId(null);
  }, [confirmCancelId, onCancelOrder]);

  const handleResetFilters = useCallback(() => {
    setStatusFilter('all');
    setSideFilter('all');
    setSearchQuery('');
    setCurrentPage(1);
  }, []);

  const hasActiveFilters = statusFilter !== 'all' || sideFilter !== 'all' || searchQuery !== '';

  // Column configuration
  const columns = compact
    ? [
        { key: 'createdAt' as keyof Order, label: 'Time', width: '80px' },
        { key: 'instrumentSymbol' as keyof Order, label: 'Instrument', width: '60px' },
        { key: 'side' as keyof Order, label: 'Side', width: '30px' },
        { key: 'type' as keyof Order, label: 'Type', width: '40px' },
        { key: 'quantity' as keyof Order, label: 'Qty', width: '50px' },
        { key: 'filledQuantity' as keyof Order, label: 'Filled', width: '50px' },
        { key: 'price' as keyof Order, label: 'Price', width: '50px' },
        { key: 'status' as keyof Order, label: 'Status', width: '60px' },
      ]
    : [
        { key: 'createdAt' as keyof Order, label: 'Time', width: '120px' },
        { key: 'instrumentSymbol' as keyof Order, label: 'Instrument', width: '80px' },
        { key: 'side' as keyof Order, label: 'Side', width: '40px' },
        { key: 'type' as keyof Order, label: 'Type', width: '60px' },
        { key: 'quantity' as keyof Order, label: 'Quantity', width: '80px' },
        { key: 'filledQuantity' as keyof Order, label: 'Filled', width: '80px' },
        { key: 'price' as keyof Order, label: 'Price', width: '80px' },
        { key: 'avgFillPrice' as keyof Order, label: 'Avg Fill', width: '80px' },
        { key: 'fees' as keyof Order, label: 'Fees', width: '60px' },
        { key: 'status' as keyof Order, label: 'Status', width: '80px' },
      ];

  if (error) {
    return (
      <div className={className} style={{ padding: 24, textAlign: 'center' }}>
        <div style={{ color: '#ef4444', marginBottom: 12 }}>Failed to load orders</div>
        <div style={{ color: '#64748b', fontSize: 12, marginBottom: 16 }}>{error}</div>
        {onRefresh && (
          <button onClick={onRefresh} style={{
            padding: '8px 16px', background: '#1e293b', border: '1px solid #334155',
            borderRadius: 6, color: '#94a3b8', cursor: 'pointer',
          }}>
            Retry
          </button>
        )}
      </div>
    );
  }

  if (loading && orders.length === 0) {
    return (
      <div className={className} style={{ padding: 40, textAlign: 'center', color: '#64748b' }}>
        <div className="spinner" style={{ margin: '0 auto 12px' }} />
        <div>Loading orders...</div>
      </div>
    );
  }

  return (
    <div className={className} ref={containerRef}>
      {/* Filters */}
      {showFilters && (
        <div style={{
          display: 'flex', alignItems: 'center', gap: 8, marginBottom: 12, flexWrap: 'wrap',
        }}>
          {/* Status filter */}
          <div style={{ display: 'flex', gap: 2 }}>
            {STATUS_FILTERS.map(f => (
              <button
                key={f.value}
                onClick={() => { setStatusFilter(f.value); setCurrentPage(1); }}
                style={{
                  padding: '4px 12px', fontSize: 12,
                  border: '1px solid', borderRadius: 4,
                  borderColor: statusFilter === f.value ? '#3b82f6' : '#334155',
                  background: statusFilter === f.value ? 'rgba(59,130,246,0.15)' : 'transparent',
                  color: statusFilter === f.value ? '#60a5fa' : '#64748b',
                  cursor: 'pointer', fontWeight: statusFilter === f.value ? 600 : 400,
                }}
              >
                {f.label}
              </button>
            ))}
          </div>

          <div style={{ width: 1, height: 20, background: '#334155' }} />

          {/* Side filter */}
          {(['all', 'buy', 'sell'] as OrderFilterSide[]).map(s => (
            <button
              key={s}
              onClick={() => { setSideFilter(s); setCurrentPage(1); }}
              style={{
                padding: '4px 12px', fontSize: 12, textTransform: 'capitalize',
                border: '1px solid', borderRadius: 4,
                borderColor: sideFilter === s ? '#3b82f6' : '#334155',
                background: sideFilter === s ? 'rgba(59,130,246,0.15)' : 'transparent',
                color: sideFilter === s ? '#60a5fa' : '#64748b',
                cursor: 'pointer', fontWeight: sideFilter === s ? 600 : 400,
              }}
            >
              {s === 'all' ? 'All' : s}
            </button>
          ))}

          {/* Search */}
          <input
            type="text"
            value={searchQuery}
            onChange={e => { setSearchQuery(e.target.value); setCurrentPage(1); }}
            placeholder="Search orders..."
            style={{
              flex: 1, minWidth: 120, padding: '4px 8px', fontSize: 12,
              background: '#0f172a', border: '1px solid #334155', borderRadius: 4,
              color: '#f8fafc', outline: 'none',
            }}
          />

          {/* Reset */}
          {hasActiveFilters && (
            <button onClick={handleResetFilters} style={{
              padding: '4px 8px', fontSize: 11, background: 'transparent',
              border: '1px solid #334155', borderRadius: 4, color: '#64748b', cursor: 'pointer',
            }}>
              Clear Filters
            </button>
          )}

          {/* Refresh */}
          {onRefresh && (
            <button onClick={onRefresh} style={{
              padding: '4px 8px', fontSize: 11, background: 'transparent',
              border: '1px solid #334155', borderRadius: 4, color: '#64748b', cursor: 'pointer',
            }}>
              ↻
            </button>
          )}
        </div>
      )}

      {/* Empty state */}
      {filteredOrders.length === 0 && !loading && (
        <div style={{ padding: 40, textAlign: 'center', color: '#64748b' }}>
          {hasActiveFilters
            ? 'No orders match the current filters.'
            : 'No orders yet. Place your first trade to get started.'}
        </div>
      )}

      {/* Order table */}
      {pageItems.length > 0 && (
        <div style={{ overflowX: 'auto', border: '1px solid #334155', borderRadius: 8 }}>
          <table style={{ width: '100%', fontSize: compact ? 11 : 13 }}>
            <thead>
              <tr>
                {columns.map(col => (
                  <th
                    key={col.key}
                    onClick={() => handleSort(col.key)}
                    style={{
                      textAlign: 'right',
                      cursor: 'pointer',
                      padding: compact ? '6px 8px' : '8px 12px',
                      width: col.width,
                      whiteSpace: 'nowrap',
                      userSelect: 'none',
                    }}
                  >
                    {col.label}
                    {sortField === col.key && (
                      <span style={{ marginLeft: 4, fontSize: 10 }}>
                        {sortDirection === 'asc' ? '▲' : '▼'}
                      </span>
                    )}
                  </th>
                ))}
                {onCancelOrder && <th style={{ width: 40 }}></th>}
              </tr>
            </thead>
            <tbody>
              {pageItems.map(order => (
                <tr
                  key={order.id}
                  onClick={() => onOrderClick?.(order)}
                  style={{
                    cursor: onOrderClick ? 'pointer' : undefined,
                    opacity: order.status === 'cancelled' || order.status === 'rejected' || order.status === 'expired' ? 0.6 : 1,
                  }}
                >
                  <td style={{ textAlign: 'right', padding: compact ? '6px 8px' : '8px 12px', whiteSpace: 'nowrap' }}>
                    {formatTimestamp(order.createdAt, compact ? 'time' : 'relative')}
                  </td>
                  <td style={{ textAlign: 'right', padding: compact ? '6px 8px' : '8px 12px', fontWeight: 600 }}>
                    {order.instrumentSymbol}
                  </td>
                  <td style={{
                    textAlign: 'center', padding: compact ? '6px 8px' : '8px 12px',
                    fontWeight: 600, color: order.side === 'buy' ? '#22c55e' : '#ef4444',
                  }}>
                    {order.side.toUpperCase()}
                  </td>
                  <td style={{ textAlign: 'center', padding: compact ? '6px 8px' : '8px 12px', fontSize: compact ? 10 : 12 }}>
                    {formatEnumValue(order.type)}
                  </td>
                  <td style={{ textAlign: 'right', padding: compact ? '6px 8px' : '8px 12px', fontFamily: 'monospace' }}>
                    {formatQuantity(order.quantity, compact ? 4 : 6)}
                  </td>
                  <td style={{ textAlign: 'right', padding: compact ? '6px 8px' : '8px 12px', fontFamily: 'monospace' }}>
                    {order.filledQuantity > 0 ? formatQuantity(order.filledQuantity, compact ? 4 : 6) : ' - '}
                  </td>
                  <td style={{ textAlign: 'right', padding: compact ? '6px 8px' : '8px 12px', fontFamily: 'monospace' }}>
                    {order.price ? formatPrice(order.price) : (order.type === 'market' ? 'Market' : ' - ')}
                  </td>
                  {!compact && (
                    <>
                      <td style={{ textAlign: 'right', padding: '8px 12px', fontFamily: 'monospace' }}>
                        {order.avgFillPrice ? formatPrice(order.avgFillPrice) : ' - '}
                      </td>
                      <td style={{ textAlign: 'right', padding: '8px 12px', fontFamily: 'monospace' }}>
                        {order.fees ? formatCurrency(order.fees, order.feeCurrency) : ' - '}
                      </td>
                    </>
                  )}
                  <td style={{ textAlign: 'center', padding: compact ? '6px 8px' : '8px 12px' }}>
                    <span style={{
                      padding: '1px 8px', borderRadius: 4, fontSize: compact ? 10 : 11,
                      background: `${statusColor(order.status)}15`,
                      color: statusColor(order.status),
                      fontWeight: 500,
                    }}>
                      {formatEnumValue(order.status)}
                    </span>
                  </td>
                  {onCancelOrder && OPEN_STATUSES.includes(order.status) && (
                    <td style={{ padding: '4px', textAlign: 'center' }}>
                      <button
                        onClick={(e) => { e.stopPropagation(); handleCancelClick(order.id); }}
                        style={{
                          padding: '2px 8px', fontSize: 10, background: 'rgba(239,68,68,0.15)',
                          border: '1px solid rgba(239,68,68,0.3)', borderRadius: 4,
                          color: '#f87171', cursor: 'pointer',
                        }}
                      >
                        Cancel
                      </button>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {/* Pagination */}
      {showPagination && pages > 1 && (
        <div style={{
          display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 4, marginTop: 12,
        }}>
          <button
            onClick={() => handlePageChange(1)}
            disabled={currentPage === 1}
            style={{ padding: '4px 8px', fontSize: 11, border: '1px solid #334155', borderRadius: 4, background: 'transparent', color: '#64748b', cursor: 'pointer', opacity: currentPage === 1 ? 0.5 : 1 }}
          >
            ««
          </button>
          <button
            onClick={() => handlePageChange(currentPage - 1)}
            disabled={currentPage === 1}
            style={{ padding: '4px 8px', fontSize: 11, border: '1px solid #334155', borderRadius: 4, background: 'transparent', color: '#64748b', cursor: 'pointer', opacity: currentPage === 1 ? 0.5 : 1 }}
          >
            «
          </button>
          <span style={{ padding: '4px 8px', fontSize: 11, color: '#94a3b8' }}>
            Page {currentPage} of {pages} ({total} orders)
          </span>
          <button
            onClick={() => handlePageChange(currentPage + 1)}
            disabled={currentPage === pages}
            style={{ padding: '4px 8px', fontSize: 11, border: '1px solid #334155', borderRadius: 4, background: 'transparent', color: '#64748b', cursor: 'pointer', opacity: currentPage === pages ? 0.5 : 1 }}
          >
            »
          </button>
          <button
            onClick={() => handlePageChange(pages)}
            disabled={currentPage === pages}
            style={{ padding: '4px 8px', fontSize: 11, border: '1px solid #334155', borderRadius: 4, background: 'transparent', color: '#64748b', cursor: 'pointer', opacity: currentPage === pages ? 0.5 : 1 }}
          >
            »»
          </button>
        </div>
      )}

      {/* Cancel confirmation dialog */}
      {confirmCancelId && (
        <div style={{
          position: 'fixed', top: 0, left: 0, right: 0, bottom: 0,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          background: 'rgba(0,0,0,0.7)', zIndex: 9999,
        }}>
          <div className="card" style={{ maxWidth: 360, width: '90%', padding: 24 }}>
            <h3 style={{ color: '#f8fafc', marginBottom: 8 }}>Cancel Order</h3>
            <p style={{ color: '#94a3b8', fontSize: 13, marginBottom: 20 }}>
              Are you sure you want to cancel this order? This action cannot be undone.
            </p>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
              <button
                onClick={() => setConfirmCancelId(null)}
                style={{ padding: '8px 16px', background: 'transparent', border: '1px solid #334155', borderRadius: 6, color: '#94a3b8', cursor: 'pointer', fontSize: 12 }}
              >
                Keep Order
              </button>
              <button
                onClick={handleConfirmCancel}
                style={{ padding: '8px 16px', background: '#ef4444', border: 'none', borderRadius: 6, color: '#fff', cursor: 'pointer', fontSize: 12, fontWeight: 600 }}
              >
                Yes, Cancel
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

export default OrderHistory;

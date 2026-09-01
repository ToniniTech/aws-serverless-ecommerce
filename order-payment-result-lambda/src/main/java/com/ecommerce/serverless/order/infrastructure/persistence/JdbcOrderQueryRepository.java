package com.ecommerce.serverless.order.infrastructure.persistence;

import com.ecommerce.serverless.order.application.OrderQueryRepository;
import com.ecommerce.serverless.order.application.OrderView;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

public final class JdbcOrderQueryRepository implements OrderQueryRepository {
    private final DataSource dataSource;

    public JdbcOrderQueryRepository(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    @Override
    public Optional<OrderView> findByOrderId(String orderId) {
        String sql = """
                SELECT o.order_id, o.status, o.total_amount, o.currency, o.version,
                       o.payment_id, o.payment_failure_code, o.payment_failure_reason,
                       o.created_at, o.updated_at,
                       i.product_id, i.product_name, i.quantity, i.unit_price, i.subtotal
                  FROM orders o
             LEFT JOIN order_items i ON i.order_id = o.order_id
                 WHERE o.order_id = ?
              ORDER BY i.product_id
                """;
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setString(1, orderId);
            try (ResultSet resultSet = statement.executeQuery()) {
                if (!resultSet.next()) return Optional.empty();
                List<OrderView.Item> items = new ArrayList<>();
                OrderView order = null;
                do {
                    if (resultSet.getString("product_id") != null) {
                        items.add(new OrderView.Item(
                                resultSet.getString("product_id"), resultSet.getString("product_name"),
                                resultSet.getInt("quantity"), resultSet.getBigDecimal("unit_price"),
                                resultSet.getBigDecimal("subtotal")));
                    }
                    if (order == null) {
                        order = new OrderView(
                                resultSet.getString("order_id"), resultSet.getString("status"),
                                resultSet.getBigDecimal("total_amount"), resultSet.getString("currency"),
                                resultSet.getLong("version"), resultSet.getString("payment_id"),
                                resultSet.getString("payment_failure_code"),
                                resultSet.getString("payment_failure_reason"),
                                resultSet.getTimestamp("created_at").toInstant(),
                                resultSet.getTimestamp("updated_at").toInstant(), List.of());
                    }
                } while (resultSet.next());
                return Optional.of(new OrderView(
                        order.orderId(), order.status(), order.totalAmount(), order.currency(), order.version(),
                        order.paymentId(), order.paymentFailureCode(), order.paymentFailureReason(),
                        order.createdAt(), order.updatedAt(), items));
            }
        } catch (SQLException exception) {
            throw new OrderPersistenceException("Could not query Order", exception);
        }
    }
}

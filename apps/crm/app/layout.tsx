import type { Metadata } from "next";
import "./styles.css";

export const metadata: Metadata = {
  title: "Demo Dice CRM",
  description: "Admin CRM for demo dice bot"
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="ko">
      <body>{children}</body>
    </html>
  );
}